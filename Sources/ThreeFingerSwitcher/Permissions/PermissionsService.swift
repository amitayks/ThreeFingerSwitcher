import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Combine
import EventKit

/// Detects and helps the user grant the permissions the app needs. Accessibility and Screen
/// Recording are required; Input Monitoring is best-effort (spike 1.3 saw no prompt for the
/// multitouch read, but we still surface it if the OS ever requires it).
@MainActor
final class PermissionsService: ObservableObject {
    enum Status { case granted, denied, unknown }

    @Published var accessibility: Status = .unknown
    @Published var screenRecording: Status = .unknown
    @Published var inputMonitoring: Status = .unknown
    /// Calendar (EventKit) authorization. Additive for the AI calendar task — NOT a required
    /// permission (it must never block other AI commands), so it stays out of `allRequiredGranted`
    /// and is requested LAZILY at first calendar-task use (see permissions-onboarding).
    @Published var calendar: Status = .unknown

    func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied
        inputMonitoring = mapHID(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
        calendar = mapEventKit(EKEventStore.authorizationStatus(for: .event))
    }

    var allRequiredGranted: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    // MARK: - Requests

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings(.accessibility)
    }

    func requestScreenRecording() {
        // Triggers the system prompt the first time; afterwards deep-link to Settings.
        _ = CGRequestScreenCaptureAccess()
        openSettings(.screenRecording)
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        openSettings(.inputMonitoring)
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

    // MARK: - Deep links

    enum Pane {
        case accessibility, screenRecording, inputMonitoring, calendar

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
}
