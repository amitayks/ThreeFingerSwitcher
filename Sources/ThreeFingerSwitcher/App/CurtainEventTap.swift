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
    /// While true the owner can answer the system password prompt: keyboard events pass (they go to
    /// the prompt, which is key) and pointer events pass only inside the prompt's window
    /// (`coreautha`). Set only by the controller, only while that prompt is open.
    var passThrough = false
    /// Sees every trusted event first; returning true HOLDS it (swallowed here, re-posted later by the
    /// silent Touch ID listener once the agent's app is in front again).
    var onTrusted: ((CGEventType, CGEvent) -> Bool)?
    /// Blind password entry (Curtain mode, after a wrong finger): hardware keys pass ONLY while this
    /// app is active — so they land in its focused password field and nowhere else.
    var ownPasswordEntry = false
    private var promptFrames: (frames: [CGRect], at: TimeInterval) = ([], 0)
    /// Intrusion reports are coalesced: at most one per `reportInterval` (input runs at 60–120 Hz).
    private var lastReport: TimeInterval = 0
    nonisolated static let reportInterval: TimeInterval = 0.25

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
        // The listener's own re-posts of held agent keys: pass untouched.
        if event.getIntegerValueField(.eventSourceUserData) == SilentOwnerListener.repostMarker {
            return Unmanaged.passUnretained(event)
        }
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        // Hardware (PID 0) needs no policy lookup — the hot path for a person's input.
        let origin: InputOrigin = pid <= 0 ? .hardware : policy().classify(sourcePID: pid)
        if origin.isTrusted {
            if onTrusted?(type, event) == true { return nil }
            return Unmanaged.passUnretained(event)
        }
        if passThrough, allowedForPrompt(type, event) { return Unmanaged.passUnretained(event) }
        if ownPasswordEntry, SilentOwnerListener.isKeyboard(type), NSApp.isActive {
            return Unmanaged.passUnretained(event)
        }
        let t = Date().timeIntervalSinceReferenceDate
        if t - lastReport >= Self.reportInterval {
            lastReport = t
            onIntrusion(type, origin)
        }
        return nil   // swallowed: the stranger's input never reaches any app
    }

    /// While the password prompt is open: keys (the prompt is the key window) and pointer events inside
    /// the prompt's own window. Everything else stays swallowed.
    private func allowedForPrompt(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if SilentOwnerListener.isKeyboard(type) { return true }
        let pointer: Set<CGEventType> = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        guard pointer.contains(type) else { return false }
        if type == .mouseMoved { return true }   // moving the pointer is harmless and needed to aim
        return promptWindowFrames().contains { $0.contains(event.location) }
    }

    /// Frames of the system authentication prompt's windows, cached for 0.5 s.
    private func promptWindowFrames() -> [CGRect] {
        let now = Date().timeIntervalSinceReferenceDate
        if now - promptFrames.at < 0.5 { return promptFrames.frames }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let frames: [CGRect] = list.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "coreautha",
                  let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: b as CFDictionary)
        }
        promptFrames = (frames, now)
        return frames
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
