import AppKit
import CoreGraphics

/// Keep Awake's **curtain**: an ACTIVE session event tap over every input event type that swallows
/// input from a person (hardware) or an untrusted process, and passes input synthesized by a trusted
/// app — so an agent keeps full control of the Mac while a stranger's touch does nothing
/// (`keep-awake-agent-curtain` D2). Each swallowed event reports an intrusion (the controller turns
/// the first one into a Touch ID prompt).
///
/// - Requires the Accessibility permission the app already holds (the `KeyboardSwitcherTap` precedent).
/// - macOS disables a tap whose callback is slow or after user-input timeouts; the callback re-enables
///   it on `tapDisabledByTimeout` / `tapDisabledByUserInput`, and a watchdog timer re-checks every 2 s.
/// - It cannot stop the power button's hardware action, Touch ID matching, or a closed lid — those are
///   outside the event stream. The raw trackpad touch stream is not an event either; the controller
///   watches it separately (`noteTouch`).
@MainActor
final class CurtainEventTap {
    /// Classifies an event's source PID. Read per event so trusted-list edits apply at once.
    private let policy: () -> InputTrustPolicy
    /// Fired for each swallowed event (type raw value + origin) — on the main thread.
    private let onIntrusion: (CGEventType, InputOrigin) -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    /// While true every event passes (a password prompt needs the keyboard). Set only by the
    /// controller, only for the password fallback path, only for the bounded auth window.
    var passThrough = false

    init(policy: @escaping () -> InputTrustPolicy, onIntrusion: @escaping (CGEventType, InputOrigin) -> Void) {
        self.policy = policy
        self.onIntrusion = onIntrusion
    }

    /// Install the tap. Returns false when macOS refuses (no Accessibility) — the caller falls back.
    func start() -> Bool {
        guard tap == nil else { return true }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<CurtainEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: Self.mask,
                                          callback: callback,
                                          userInfo: selfPtr) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let tap = self?.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        passThrough = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let origin = policy().classify(sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID))
        if origin.isTrusted || passThrough { return Unmanaged.passUnretained(event) }
        onIntrusion(type, origin)
        return nil   // swallowed: the stranger's input never reaches any app
    }

    /// Every event type (`kCGEventMaskForAllEvents`): pointer, keys, modifiers, scroll, tablet,
    /// gestures (swipe/magnify/rotate — Mission Control and Space swipes), and system-defined events
    /// (media keys, the power / Touch ID button press).
    static let mask: CGEventMask = ~CGEventMask(0)
}

extension CGEventType {
    /// Readable name for the guard log.
    var guardLogName: String {
        switch self {
        case .mouseMoved: return "mouseMoved"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return "mouseDown"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return "mouseUp"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return "mouseDragged"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .flagsChanged: return "flagsChanged"
        case .scrollWheel: return "scroll"
        default: return "type\(rawValue)"   // 14 = systemDefined (power/Touch ID, media keys), 29+ = gestures
        }
    }
}
