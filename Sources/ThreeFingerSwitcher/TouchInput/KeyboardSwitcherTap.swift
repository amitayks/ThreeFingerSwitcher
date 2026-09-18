import CoreGraphics
import Foundation

/// A session-level `CGEventTap` that intercepts ⌘-Tab to drive the window switcher (opt-in
/// `commandTabSwitcher`). While the ⌘ modifier is held it CONSUMES `Tab` / Shift+`Tab` — so the native
/// application-switcher HUD never appears — and, while a session is active, `Escape`. Every other event
/// passes through untouched: ⌘ with any non-Tab key, a bare Tab, and all modifier changes. It decodes
/// events and forwards semantic transitions to a `KeyboardSwitcherInput` (the pure state machine);
/// the consume/pass decision lives here (the event layer), the session logic there.
///
/// Sibling to `ScrollEventTap`: same `.cgSessionEventTap` `.defaultTap`, same main-run-loop callback,
/// same self-heal on `.tapDisabledBy*`. The active/consuming tap relies on the already-granted
/// Accessibility (as the scroll tap does; the app also holds the tracked Input Monitoring). The handler
/// is minimal and never inspects key CONTENT beyond the Tab/Esc keycodes and the ⌘/⇧ flags.
@MainActor
final class KeyboardSwitcherTap {
    /// The state machine driven by decoded events (weak: the coordinator owns both).
    weak var input: KeyboardSwitcherInput?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Health watchdog — same rationale as ScrollEventTap's: the in-band `tapDisabledByTimeout`
    /// self-heal only runs when the next event arrives, so a system-disabled tap otherwise drops
    /// the first post-stall ⌘-Tab. Re-enables independently of event delivery.
    private var watchdog: Timer?
    private static let watchdogInterval: TimeInterval = 2.0
    private(set) var isRunning = false

    /// Whether ⌘ is currently held (tracked from `flagsChanged`); gates Tab consumption.
    private var commandHeld = false
    /// Keycodes whose keyDown we consumed, so we consume the matching keyUp too — no half-event ever
    /// leaks to the focused app, regardless of any state change between the down and the up.
    private var consumedKeyDowns: Set<Int64> = []

    private let kTab: Int64 = 48       // kVK_Tab (layout-independent virtual keycode)
    private let kEscape: Int64 = 53    // kVK_Escape

    /// Arrow-key navigation of the OPEN switcher (Windows-Alt-Tab style). Only consumed while a session
    /// is active, so ⌘-arrow shortcuts are untouched when the switcher isn't open.
    private static func arrow(for keycode: Int64) -> SwitcherArrow? {
        switch keycode {
        case 123: return .left       // kVK_LeftArrow
        case 124: return .right      // kVK_RightArrow
        case 125: return .down       // kVK_DownArrow
        case 126: return .up         // kVK_UpArrow
        default:  return nil
        }
    }

    /// Start the tap. Returns false if it couldn't be created (e.g. the required access is not granted).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
                             | (1 << CGEventType.keyUp.rawValue)
                             | (1 << CGEventType.flagsChanged.rawValue))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyboardSwitcherTap>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handle(type: type, event: event) }
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,           // active tap: can consume
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: selfPtr) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviveIfDisabled() }
        }
        watchdog?.tolerance = Self.watchdogInterval / 2   // cheap check; let the OS coalesce it
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        watchdog?.invalidate()
        watchdog = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Destroy the mach receive right deterministically — the gate refreshes cycle
            // start/stop on every toggle flip, and relying on CF dealloc leaves port teardown
            // timing to autorelease.
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        isRunning = false
        commandHeld = false
        consumedKeyDowns.removeAll()
    }

    private func reviveIfDisabled() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        // The tap was disabled, so events (a ⌘-up among them) were delivered past us — see `resync`.
        resyncCommandState(from: CGEventSource.flagsState(.combinedSessionState))
    }

    /// Re-derive `commandHeld` from an authoritative flag set. While the tap is disabled (a stall in
    /// the deferred ⌘-Tab open — the snapshot's AX round-trips — is enough to trip the WindowServer's
    /// timeout) the WindowServer delivers events past it, so the `flagsChanged` for a ⌘ release is
    /// never seen; `commandHeld` then stays true, the session stays `.active`, and every BARE Tab, Esc
    /// and arrow system-wide is swallowed until the user happens to press and release ⌘ again. Every
    /// re-enable path and every key event therefore re-derives the modifier state instead of trusting
    /// the last observed transition.
    private func resyncCommandState(from flags: CGEventFlags) {
        let nowCmd = flags.contains(.maskCommand)
        if nowCmd && !commandHeld { commandHeld = true; input?.commandDown() }
        else if !nowCmd && commandHeld { commandHeld = false; input?.commandUp() }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // The system disables the tap if our callback stalls or input is interrupted; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resyncCommandState(from: CGEventSource.flagsState(.combinedSessionState))
            return pass
        }
        switch type {
        case .flagsChanged:
            // Track ⌘ and drive the session's arm/commit edges; NEVER consume a modifier change (other
            // apps must still see ⌘ press/release — we simply also emit no Tab in between).
            resyncCommandState(from: event.flags)
            return pass
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // The event's own flags are authoritative for THIS keystroke: a missed ⌘ transition (tap
            // disabled in between) is corrected here before the consume decision, so a bare Tab is never
            // swallowed on stale state and a ⌘-Tab after a missed ⌘-down still opens the session.
            resyncCommandState(from: event.flags)
            if code == kTab && commandHeld {
                input?.tab(shift: event.flags.contains(.maskShift))
                consumedKeyDowns.insert(code)
                return nil                          // swallow ⌘-Tab so the native HUD never appears
            }
            if code == kEscape && (input?.isActive ?? false) {
                input?.escape()
                consumedKeyDowns.insert(code)
                return nil                          // swallow Esc so it doesn't reach the focused app
            }
            if (input?.isActive ?? false), let arrow = Self.arrow(for: code) {
                input?.arrow(arrow)                 // navigate the OPEN switcher (⌘-arrow, session active)
                consumedKeyDowns.insert(code)
                return nil                          // swallow so ⌘-arrow doesn't reach the focused app
            }
            return pass                             // ⌘ + non-Tab, bare Tab, everything else
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return consumedKeyDowns.remove(code) != nil ? nil : pass
        default:
            return pass
        }
    }
}
