import AppKit
import CoreGraphics
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// Keep Awake's **silent owner check** (`keep-awake-silent-touch-id`): Touch ID listens behind the
/// curtain with no prompt, so the owner's finger on the sensor ends the session and a stranger gets
/// no hint at all.
///
/// Live facts this rests on (owner-verified on hardware, macOS 27, 2026-10-10):
/// - An `LAAuthenticationView` in an almost-transparent 2×2 window reads a resting finger in ~1–2 s
///   with **no system prompt** — but ONLY while this app is the active app and that window is key.
/// - The same view in a window of an inactive app never reads the finger.
///
/// So the listener owns focus whenever it can:
/// - It takes focus when a person touches the Mac (`attend`, also shows the fingerprint icon) and
///   when the trusted agent has been idle for `idleGrab` seconds (silent, icon hidden).
/// - It gives focus back the moment the agent acts: a trusted key event that arrives while this app
///   is active is held, the agent's app is re-activated, and the held keys are re-posted ~0.15 s later
///   (marked with `repostMarker` so the curtain passes them untouched). Agent clicks activate their
///   target app by themselves.
/// - Wrong finger / Touch ID lockout → `.failed` (the controller decides: password prompt or lock).
///   Cancels caused by losing focus are not failures; the listener re-arms when it is in front again.
@MainActor
final class SilentOwnerListener {
    enum Result: Equatable { case success, failed }

    /// Agent idle time after which the listener takes focus by itself.
    nonisolated static let idleGrab: TimeInterval = 15
    /// Delay between re-activating the agent's app and re-posting its held keys.
    nonisolated static let handBackDelay: TimeInterval = 0.15
    /// `eventSourceUserData` stamp on re-posted agent keys (the curtain passes them as-is).
    nonisolated static let repostMarker: Int64 = 0x5446_5343   // "TFSC"

    private let onResult: (Result) -> Void
    private var window: NSWindow?
    private var context: LAContext?
    private var evaluating = false
    /// Bumped per evaluation and on cancel: a late answer from an old context is ignored.
    private var generation = 0
    private var paused = false
    private var handingBack = false
    private var held: [CGEvent] = []
    private var returnApp: NSRunningApplication?
    private var lastTrusted = Date().timeIntervalSinceReferenceDate
    private var lastGrab: TimeInterval = 0
    private var retryAfter: TimeInterval = 0
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Touch ID can read a finger now (no sensor / clamshell / lockout → false; the controller then
    /// uses the visible prompt instead).
    static func available() -> Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    init(onResult: @escaping (Result) -> Void) {
        self.onResult = onResult
    }

    private var now: TimeInterval { Date().timeIntervalSinceReferenceDate }
    private var isFront: Bool { NSApp.isActive }

    // MARK: - Lifecycle

    func start() {
        let w = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true          // agent clicks fall through to the app underneath
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        window = w
        hideIcon()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.otherAppActivated(app) }
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        takeFocus()   // listen from the first second (the agent is idle at arm time)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        cancelEvaluation()
        flushHeld()
        let wasFront = isFront
        window?.orderOut(nil)
        window = nil
        // Give the screen back to the app that was in front before the curtain took focus.
        if wasFront, let app = returnApp, !app.isTerminated { app.activate() }
    }

    /// A person touched the Mac: take focus now and show the fingerprint icon (the owner's cue).
    func attend() {
        paused = false
        retryAfter = 0
        showIcon()
        takeFocus()
    }

    /// Pause while the visible password prompt is up (it needs focus); resume afterwards.
    func setPaused(_ on: Bool) {
        paused = on
        if on { cancelEvaluation() } else { retryAfter = 0 }
    }

    // MARK: - Agent input (called by the curtain tap for every trusted event)

    /// Returns true when the event was HELD (the curtain swallows it; it is re-posted after focus
    /// returns to the agent's app). Only keyboard events need this: they go to the key window — ours.
    func noteTrusted(_ type: CGEventType, _ event: CGEvent) -> Bool {
        lastTrusted = now
        guard isFront || handingBack, Self.isKeyboard(type), let copy = event.copy() else { return false }
        copy.setIntegerValueField(.eventSourceUserData, value: Self.repostMarker)
        held.append(copy)
        if !handingBack { handBack() }
        return true
    }

    nonisolated static func isKeyboard(_ type: CGEventType) -> Bool {
        type == .keyDown || type == .keyUp || type == .flagsChanged
    }

    private func handBack() {
        handingBack = true
        cancelEvaluation()
        hideIcon()
        if let app = returnApp, !app.isTerminated { app.activate() } else { NSApp.hide(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handBackDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.handingBack else { return }
                self.flushHeld()
            }
        }
    }

    private func flushHeld() {
        let events = held
        held = []
        handingBack = false
        for e in events { e.post(tap: .cgSessionEventTap) }
    }

    // MARK: - Focus + evaluation

    private func otherAppActivated(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != getpid() else { return }
        returnApp = app
        // Touch ID stops reading once we are not in front; drop the context so the next grab is clean.
        cancelEvaluation()
        hideIcon()
    }

    private func tick() {
        guard !paused, !handingBack else { return }
        if isFront {
            if !evaluating { window?.makeKey(); startEvaluation() }
        } else if now - lastTrusted >= Self.idleGrab, now - lastGrab >= 5 {
            takeFocus()
        }
    }

    private func takeFocus() {
        guard !paused, !handingBack, let window else { return }
        lastGrab = now
        if !isFront {
            if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
                returnApp = front
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        window.orderFrontRegardless()
        window.makeKey()
        startEvaluation()
    }

    private func startEvaluation() {
        guard !evaluating, !paused, now >= retryAfter, let window else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        let view = LAAuthenticationView(context: ctx, controlSize: .large)
        view.frame = NSRect(origin: .zero, size: window.frame.size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        context = ctx
        evaluating = true
        generation += 1
        let g = generation
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "end Keep Awake") { [weak self] ok, error in
            let code = (error as? LAError)?.code
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.evaluationEnded(g, ok: ok, code: code) }
            }
        }
    }

    private func evaluationEnded(_ g: Int, ok: Bool, code: LAError.Code?) {
        guard g == generation, evaluating else { return }   // a cancelled context's late answer
        context = nil
        evaluating = false
        if ok { onResult(.success); return }
        switch code {
        case .authenticationFailed?, .biometryLockout?:
            // A finger was read and it is not the owner's (or Touch ID gave up): stop listening until
            // the controller resumes us after the visible prompt.
            paused = true
            onResult(.failed)
        default:
            // Lost focus, system cancel, not interactive…: not an answer. Re-arm on the next tick.
            retryAfter = now + 1
        }
    }

    private func cancelEvaluation() {
        generation += 1
        guard let ctx = context else { evaluating = false; return }
        context = nil
        evaluating = false
        ctx.invalidate()
    }

    // MARK: - The fingerprint icon

    private func showIcon() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let side: CGFloat = 96
        let f = screen.frame
        window.setFrame(NSRect(x: f.midX - side / 2, y: f.midY - side / 2, width: side, height: side), display: true)
        window.alphaValue = 1
    }

    private func hideIcon() {
        guard let window else { return }
        window.setFrame(NSRect(x: 0, y: 0, width: 2, height: 2), display: false)
        window.alphaValue = 0.01   // not 0: a fully transparent window is not key-able for Touch ID
    }
}

/// A borderless window that can become key (Touch ID reads only for the key window of the active app).
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
