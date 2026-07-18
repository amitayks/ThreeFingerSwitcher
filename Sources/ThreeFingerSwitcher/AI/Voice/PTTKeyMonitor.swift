import Foundation
import AppKit

/// The push-to-talk trigger monitor (`add-voice-computer-use-agent` D4; **double-tap-then-hold**
/// grammar by `voice-double-tap-dwell-trigger`): passive `flagsChanged` + `keyDown` monitors
/// tracking one bare modifier (default **Right Option**, keyCode 61). Click, then press-and-HOLD
/// within the gap — capture begins at dwell-elapsed (`onDown`), release sends (`onUp`). Long single
/// holds, bare double-taps, and any typing chord are structural no-ops that never touch the capture
/// stack. Nothing is consumed or delayed; no new permission. The decision logic is the pure,
/// unit-tested `PTTArmingModel` — this class is the NSEvent/one-timer driver.
@MainActor
public final class PTTKeyMonitor {

    /// Right Option. Configurable via `AppSettings.voicePTTKeyCode`.
    public static let defaultKeyCode: UInt16 = 61

    public var onDown: (@MainActor () -> Void)?
    public var onUp: (@MainActor () -> Void)?
    /// Timer-duration scale (tests shrink it; production 1.0).
    public var timerScale: Double = 1.0

    private var keyCode: UInt16
    private var monitors: [Any] = []
    private var flagIsDown = false
    private var model = PTTArmingModel()
    private var pendingTimer: DispatchWorkItem?

    public init(keyCode: UInt16 = PTTKeyMonitor.defaultKeyCode) {
        self.keyCode = keyCode
    }

    public func setKeyCode(_ code: UInt16) {
        keyCode = code
        reset()
    }

    public func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event   // ALWAYS passed through — observation only
        }) {
            monitors.append(local)
        }
    }

    public func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        reset()
    }

    private func reset() {
        pendingTimer?.cancel()
        pendingTimer = nil
        flagIsDown = false
        model = PTTArmingModel()
    }

    // MARK: - Event driving

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Passive chord signal: any real key while arming = typing, never talk.
            perform(model.handle(.otherKeyDown))
        case .flagsChanged:
            guard event.keyCode == keyCode else { return }
            let downNow = event.modifierFlags.contains(flagFamily(for: keyCode))
            guard downNow != flagIsDown else { return }
            flagIsDown = downNow
            perform(model.handle(downNow ? .pttFlagDown : .pttFlagUp))
        default:
            break
        }
    }

    private func perform(_ actions: [PTTArmingModel.Action]) {
        for action in actions {
            switch action {
            case let .schedule(kind):
                pendingTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingTimer = nil
                        self.perform(self.model.handle(.timerFired))
                    }
                }
                pendingTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + kind.duration * timerScale,
                                              execute: work)
            case .cancelTimer:
                pendingTimer?.cancel()
                pendingTimer = nil
            case .firePTTDown:
                onDown?()
            case .firePTTUp:
                onUp?()
            }
        }
    }

    private func flagFamily(for code: UInt16) -> NSEvent.ModifierFlags {
        switch code {
        case 61, 58: return .option
        case 62, 59: return .control
        case 60, 56: return .shift
        case 54, 55: return .command
        case 63:     return .function
        default:     return .option
        }
    }
}
