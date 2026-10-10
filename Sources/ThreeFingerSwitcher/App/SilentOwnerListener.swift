import AppKit
import CoreGraphics
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import OpenDirectory

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
/// - Wrong finger → `.failed` at once (the controller decides: password prompt or lock). An embedded
///   evaluation does NOT end on a wrong finger — the system silently retries (owner test 2026-10-10) —
///   so a `NoMatchWatcher` reads the system's own "no-match" log line. Touch ID lockout also ends in
///   `.failed`. Cancels caused by losing focus are not failures; the listener re-arms in front again.
/// - With `passwordOnNoMatch` (Curtain mode) a wrong finger does not report `.failed`: the listener
///   switches to **blind password entry** — a focused secure field in its own key window, so the owner
///   types the login password and presses Return even on a screen dimmed to black (no click on "Use
///   Password…"). The password is checked with OpenDirectory; while entry is open the curtain passes
///   hardware keys ONLY while this app is active (they land in the field). 30 s without a key, or 5
///   wrong passwords, return to silent Touch ID listening.
@MainActor
final class SilentOwnerListener {
    enum Result: Equatable { case success, failed }

    /// Agent idle time after which the listener takes focus by itself.
    nonisolated static let idleGrab: TimeInterval = 15
    /// Delay between re-activating the agent's app and re-posting its held keys.
    nonisolated static let handBackDelay: TimeInterval = 0.15
    /// `eventSourceUserData` stamp on re-posted agent keys (the curtain passes them as-is).
    nonisolated static let repostMarker: Int64 = 0x5446_5343   // "TFSC"

    /// Owner-check outcomes.
    private let onResult: (Result) -> Void
    /// Curtain mode: a wrong finger opens blind password entry instead of reporting `.failed`.
    private let passwordOnNoMatch: Bool
    /// Lets the curtain pass hardware keys into the password field (set only during entry).
    var setKeyPassThrough: (Bool) -> Void = { _ in }
    nonisolated static let passwordIdleTimeout: TimeInterval = 30
    nonisolated static let maxPasswordTries = 5
    private var passwordField: NSSecureTextField?
    private var passwordTries = 0
    private var passwordDeadline: DispatchWorkItem?
    private var verifying = false
    /// Where the Touch ID view sits during password entry (nil otherwise).
    private var touchIDSlot: NSView?
    private var passwordCard: CurtainPasswordCard?
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
    private var noMatchWatcher: NoMatchWatcher?

    /// Touch ID can read a finger now (no sensor / clamshell / lockout → false; the controller then
    /// uses the visible prompt instead).
    static func available() -> Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    init(passwordOnNoMatch: Bool = false, onResult: @escaping (Result) -> Void) {
        self.passwordOnNoMatch = passwordOnNoMatch
        self.onResult = onResult
    }

    /// True while blind password entry is open.
    var inPasswordEntry: Bool { passwordField != nil }

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
        let watcher = NoMatchWatcher { [weak self] in self?.fingerNotRecognized() }
        watcher.start()
        noMatchWatcher = watcher
        takeFocus()   // listen from the first second (the agent is idle at arm time)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        noMatchWatcher?.stop()
        noMatchWatcher = nil
        endPasswordEntry(resume: false)
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
        if inPasswordEntry { focusPasswordField(); return }
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
        guard isFront || handingBack || inPasswordEntry, Self.isKeyboard(type), let copy = event.copy() else { return false }
        copy.setIntegerValueField(.eventSourceUserData, value: Self.repostMarker)
        held.append(copy)
        // During password entry the agent waits: its keys must not land in the owner's field.
        if !handingBack, !inPasswordEntry { handBack() }
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
        // Password entry: Touch ID keeps listening beside the field (another enrolled finger works).
        if inPasswordEntry {
            if isFront, !evaluating, !verifying { startEvaluation() }
            return
        }
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
        guard !evaluating, now >= retryAfter, let window else { return }
        guard !paused || inPasswordEntry else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        if let slot = touchIDSlot {
            // Password entry: the sensor icon sits beside the field; the field keeps keyboard focus.
            slot.subviews.forEach { $0.removeFromSuperview() }
            let view = LAAuthenticationView(context: ctx, controlSize: .regular)
            view.frame = slot.bounds
            view.autoresizingMask = [.width, .height]
            slot.addSubview(view)
            if let field = passwordField { window.makeFirstResponder(field) }
        } else {
            let view = LAAuthenticationView(context: ctx, controlSize: .large)
            view.frame = NSRect(origin: .zero, size: window.frame.size)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
        }
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
        if ok {
            if inPasswordEntry { GuardLog.write("password-entry closed by touch id") }
            endPasswordEntry(resume: false)
            onResult(.success)
            return
        }
        if inPasswordEntry {
            // Wrong finger again or lockout: the password field stays; re-arm Touch ID unless locked out.
            retryAfter = now + (code == .biometryLockout ? 3600 : 1)
            return
        }
        switch code {
        case .authenticationFailed?, .biometryLockout?:
            // A finger was read and it is not the owner's (or Touch ID gave up).
            wrongFinger()
        default:
            // Lost focus, system cancel, not interactive…: not an answer. Re-arm on the next tick.
            retryAfter = now + 1
        }
    }

    /// The system reported a wrong finger. Only OUR silent evaluation counts (the visible prompt has
    /// its own retries and its password option).
    private func fingerNotRecognized() {
        guard evaluating, !paused, isFront else { return }
        cancelEvaluation()
        wrongFinger()
    }

    private func wrongFinger() {
        paused = true
        if passwordOnNoMatch { beginPasswordEntry() } else { onResult(.failed) }
    }

    // MARK: - Blind password entry (Curtain mode, after a wrong finger)

    private func beginPasswordEntry() {
        guard let window, passwordField == nil else { return }
        passwordTries = 0
        let card = CurtainPasswordCard()
        let side = CurtainPasswordCard.size
        touchIDSlot = card.touchIDSlot
        passwordCard = card
        let field = card.field
        field.target = self
        field.action = #selector(passwordSubmitted(_:))
        window.contentView = card
        window.hasShadow = true
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.frame
            window.setFrame(NSRect(x: f.midX - side.width / 2, y: f.midY - side.height / 2,
                                   width: side.width, height: side.height), display: true)
        }
        window.alphaValue = 1
        passwordField = field
        setKeyPassThrough(true)
        retryAfter = now + 1          // the wrong finger is probably still on the sensor
        focusPasswordField()
        armPasswordDeadline()
        GuardLog.write("password-entry open (finger not recognized)")
    }

    private func focusPasswordField() {
        guard let window, let field = passwordField else { return }
        if !isFront { NSApp.activate(ignoringOtherApps: true) }
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(field)
        armPasswordDeadline()
    }

    private func armPasswordDeadline() {
        passwordDeadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endPasswordEntry(resume: true) }
        }
        passwordDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.passwordIdleTimeout, execute: work)
    }

    @objc private func passwordSubmitted(_ sender: NSSecureTextField) {
        let password = sender.stringValue
        guard !password.isEmpty, !verifying else { return }
        verifying = true
        armPasswordDeadline()
        let user = NSUserName()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.verifyLoginPassword(user: user, password: password)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.passwordChecked(ok) }
            }
        }
    }

    private func passwordChecked(_ ok: Bool) {
        verifying = false
        guard let field = passwordField else { return }
        if ok {
            GuardLog.write("password-entry ok")
            endPasswordEntry(resume: false)
            onResult(.success)
            return
        }
        passwordTries += 1
        field.stringValue = ""
        passwordCard?.shake()
        GuardLog.write("password-entry wrong (\(passwordTries))")
        if passwordTries >= Self.maxPasswordTries {
            endPasswordEntry(resume: true)
            retryAfter = now + 30
        }
    }

    /// Close entry. `resume` returns to silent Touch ID listening (timeout / too many tries).
    private func endPasswordEntry(resume: Bool) {
        passwordDeadline?.cancel()
        passwordDeadline = nil
        guard passwordField != nil else { return }
        cancelEvaluation()
        touchIDSlot = nil
        passwordCard = nil
        window?.hasShadow = false
        retryAfter = 0
        passwordField?.stringValue = ""
        passwordField = nil
        setKeyPassThrough(false)
        hideIcon()
        if resume {
            GuardLog.write("password-entry closed")
            paused = false
            if !held.isEmpty { handBack() }
        }
    }

    /// The login password check (OpenDirectory, the local user's record). Never logs the password.
    nonisolated static func verifyLoginPassword(user: String, password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
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

/// Watches the system log for Touch ID's "no-match" (a finger was read and it is not enrolled).
/// LocalAuthentication has no public per-attempt callback, and an embedded evaluation keeps retrying
/// silently, so this is the only signal for "wrong finger" before lockout. `/usr/bin/log stream` runs
/// as the user (admin needed to read the log; without it nothing arrives and lockout stays the
/// fallback). Fail-soft: if Apple changes the message, the listener still works, it just waits for
/// lockout to show the prompt.
@MainActor
final class NoMatchWatcher {
    nonisolated static let predicate = #"process == "coreauthd" AND eventMessage CONTAINS "received no-match""#
    private let onNoMatch: () -> Void
    private var process: Process?
    private var buffer = ""

    init(onNoMatch: @escaping () -> Void) { self.onNoMatch = onNoMatch }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(text) } }
        }
        do { try p.run(); process = p } catch { pipe.fileHandleForReading.readabilityHandler = nil }
    }

    func stop() {
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
    }

    /// Exposed for tests: feed raw stream text; fires once per no-match line.
    func consume(_ text: String) {
        buffer += text
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if Self.isNoMatch(line) { onNoMatch() }
        }
    }

    nonisolated static func isNoMatch(_ line: String) -> Bool {
        line.contains("coreauthd") && line.contains("received no-match")
    }
}
