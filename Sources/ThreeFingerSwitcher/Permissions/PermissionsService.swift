import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Combine
import EventKit
import Contacts

/// Detects and helps the user grant the permissions the app needs. Accessibility and Screen
/// Recording are required; Input Monitoring is best-effort (spike 1.3 saw no prompt for the
/// multitouch read, but we still surface it if the OS ever requires it).
@MainActor
final class PermissionsService: ObservableObject {
    enum Status: Equatable { case granted, denied, unknown }

    @Published var accessibility: Status = .unknown
    @Published var screenRecording: Status = .unknown
    @Published var inputMonitoring: Status = .unknown
    /// Calendar (EventKit) authorization. Additive for the AI calendar task — NOT a required
    /// permission (it must never block other AI commands), so it stays out of `allRequiredGranted`
    /// and is requested LAZILY at first calendar-task use (see permissions-onboarding).
    @Published var calendar: Status = .unknown
    /// Reminders (EventKit) authorization — additive for the AI reminder task, lazy first-use only.
    @Published var reminders: Status = .unknown
    /// Contacts authorization — additive for the AI new-contact task, lazy first-use only.
    @Published var contacts: Status = .unknown

    func refresh() {
        // Assign only on change so the poll doesn't spam objectWillChange every second.
        setIfChanged(\.accessibility, AXIsProcessTrusted() ? .granted : .denied)
        setIfChanged(\.screenRecording, CGPreflightScreenCaptureAccess() ? .granted : .denied)
        setIfChanged(\.inputMonitoring, mapHID(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))
        setIfChanged(\.calendar, mapEventKit(EKEventStore.authorizationStatus(for: .event)))
        setIfChanged(\.reminders, mapEventKit(EKEventStore.authorizationStatus(for: .reminder)))
        setIfChanged(\.contacts, mapContacts(CNContactStore.authorizationStatus(for: .contacts)))
    }

    private func setIfChanged(_ keyPath: ReferenceWritableKeyPath<PermissionsService, Status>, _ value: Status) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    var allRequiredGranted: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    // MARK: - Live polling (the wizard's permission acts and the Hub Setup page poll while visible)

    /// Reference-counted so overlapping surfaces (a wizard act + the Setup page) compose: the timer
    /// lives while at least one `startPolling()` is unbalanced. A `didBecomeActive` refresh rides
    /// along so returning from System Settings updates instantly even between ticks.
    private var pollCount = 0
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Injectable for tests: builds the (already-scheduled) repeating poll timer.
    var pollTimerFactory: (TimeInterval, @escaping @MainActor () -> Void) -> Timer = { interval, tick in
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
    }

    var isPolling: Bool { pollTimer != nil }

    func startPolling(interval: TimeInterval = 1.0) {
        pollCount += 1
        guard pollTimer == nil else { return }
        refresh()
        pollTimer = pollTimerFactory(interval) { [weak self] in self?.refresh() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        pollCount = max(0, pollCount - 1)
        guard pollCount == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: - Requests

    // The OS consent dialog and a parallel Settings deep-link are redundant together (the dialog's
    // own button opens the exact pane) — showing both was a double-surface bug. But the dialog is
    // ALSO what registers the app's row in the pane's list on the first-ever request, so it can't
    // simply be skipped. The split: the FIRST request fires the OS dialog only; every later
    // request deep-links the pane only, silently. The once-flags live in the app's preferences, so
    // a Danger-zone data wipe (which also resets TCC, removing the row) correctly starts over.

    /// Pure: the first-ever request shows the system dialog (which registers the app's row);
    /// later requests go straight to the System Settings pane.
    static func shouldShowSystemPrompt(alreadyPrompted: Bool) -> Bool { !alreadyPrompted }

    private let defaults = UserDefaults.standard
    private enum PromptOnceKeys {
        static let accessibility = "didRequestAccessibilityPrompt"
        static let screenRecording = "didRequestScreenRecordingPrompt"
        static let inputMonitoring = "didRequestInputMonitoringPrompt"
    }

    func requestAccessibility() {
        if Self.shouldShowSystemPrompt(alreadyPrompted: defaults.bool(forKey: PromptOnceKeys.accessibility)) {
            defaults.set(true, forKey: PromptOnceKeys.accessibility)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else {
            openSettings(.accessibility)
        }
    }

    func requestScreenRecording() {
        if Self.shouldShowSystemPrompt(alreadyPrompted: defaults.bool(forKey: PromptOnceKeys.screenRecording)) {
            defaults.set(true, forKey: PromptOnceKeys.screenRecording)
            _ = CGRequestScreenCaptureAccess()
        } else {
            openSettings(.screenRecording)
        }
    }

    func requestInputMonitoring() {
        if Self.shouldShowSystemPrompt(alreadyPrompted: defaults.bool(forKey: PromptOnceKeys.inputMonitoring)) {
            defaults.set(true, forKey: PromptOnceKeys.inputMonitoring)
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            openSettings(.inputMonitoring)
        }
    }

    // MARK: - Calendar (EventKit) — lazy, first-use for the calendar task

    /// The current Calendar authorization, without prompting. `granted` only for full write access
    /// (write-only/limited can't reliably create arbitrary events for our use).
    var hasCalendarAccess: Bool {
        mapEventKit(EKEventStore.authorizationStatus(for: .event)) == .granted
    }

    /// Request Calendar access lazily (first calendar-task use only — never at launch / opt-in). Uses
    /// `requestFullAccessToEvents` (macOS 14+). Returns whether access is granted; updates `calendar`.
    /// A denied/restricted result returns `false` so the task can fail gracefully (no event created,
    /// the user is told access is required) without blocking other AI commands.
    @discardableResult
    func requestCalendarAccess(using store: EKEventStore = EKEventStore()) async -> Bool {
        // Already decided: don't re-prompt; just report the standing decision.
        let current = EKEventStore.authorizationStatus(for: .event)
        if current == .fullAccess {
            calendar = .granted
            return true
        }
        if current == .denied || current == .restricted {
            calendar = .denied
            return false
        }
        // .notDetermined (and write-only) → prompt now (first use).
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        calendar = granted ? .granted : .denied
        return granted
    }

    // MARK: - Reminders (EventKit) — lazy, first-use for the reminder task

    /// Request Reminders access lazily (first reminder-task use only). Mirrors `requestCalendarAccess`.
    @discardableResult
    func requestRemindersAccess(using store: EKEventStore = EKEventStore()) async -> Bool {
        let current = EKEventStore.authorizationStatus(for: .reminder)
        if current == .fullAccess { reminders = .granted; return true }
        if current == .denied || current == .restricted { reminders = .denied; return false }
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        reminders = granted ? .granted : .denied
        return granted
    }

    // MARK: - Contacts — lazy, first-use for the new-contact task

    /// Request Contacts access lazily (first contact-task use only). Returns whether write access is
    /// granted; updates `contacts`. A denied/restricted result returns `false` so the task fails
    /// gracefully without blocking other AI commands.
    @discardableResult
    func requestContactsAccess(using store: CNContactStore = CNContactStore()) async -> Bool {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        if current == .authorized { contacts = .granted; return true }
        if current == .denied || current == .restricted { contacts = .denied; return false }
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        contacts = granted ? .granted : .denied
        return granted
    }

    // MARK: - Deep links

    enum Pane {
        case accessibility, screenRecording, inputMonitoring, calendar, reminders, contacts

        var urlString: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .screenRecording:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            case .calendar:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            case .reminders:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
            case .contacts:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
            }
        }
    }

    func openSettings(_ pane: Pane) {
        if let url = URL(string: pane.urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func mapHID(_ access: IOHIDAccessType) -> Status {
        switch access {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    private func mapEventKit(_ status: EKAuthorizationStatus) -> Status {
        switch status {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown   // .notDetermined / .writeOnly → undecided for our full-write need
        }
    }

    private func mapContacts(_ status: CNAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown   // .notDetermined → undecided
        }
    }
}
