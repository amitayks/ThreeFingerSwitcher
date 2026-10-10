import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// The stateful owner of the **Keep Awake** automation (`automations` capability). Unlike every
/// one-shot launcher action, this is a *mode you enter and leave*: firing the `.automation(.keepAwake)`
/// item TOGGLES it (see `LaunchService.onAutomation` → `AppCoordinator`).
///
/// While active it (design D2, "awake-but-dark"):
///   • dims **every** active display to the configured level (snapshotting each first, restoring on stop),
///   • optionally does the same to every keyboard backlight (`Config.dimKeyboard` — the second
///     symmetric session effect, `keep-awake-guard-effects` D1),
///   • holds a `ProcessInfo.beginActivity` assertion that blocks system sleep, display sleep, and thus
///     the idle screen lock — public API, **no new permission** (the `ModelManager` precedent),
///   • runs a ~5-minute heartbeat that re-pins brightness (display + keyboard) and re-declares user
///     activity as a safety net.
///
/// It stops on the **next input after the triggering gesture lifts** (design D3): after start it waits
/// for one empty frame (the firing gesture released) to ARM, then the next trackpad contact stops it —
/// so the trigger can never self-cancel. With `Config.lockOnStop` (the **guard**,
/// `keep-awake-guard-effects` D2/D3), arming also installs a passive any-input monitor (mouse/keys),
/// and an input-path stop **locks the screen first, then restores** — so a stranger's touch lands on
/// the lock screen, never a flash of the unlocked desktop. Explicit/teardown stops never lock.
/// Teardown is idempotent and also runs on quit / will-sleep so a dimmed-to-black screen and a held
/// assertion are never stranded (design D4).
///
/// The side effects are behind an injectable `Effects` seam so the whole start→arm→stop lifecycle is
/// unit-tested with recording fakes; the live power/brightness/lock behavior is user-run-verified.
@MainActor
final class KeepAwakeController {
    /// The per-session configuration, resolved from the fired item's authored settings.
    struct Config: Equatable {
        /// The 0…1 level the displays dim to (and the heartbeat re-pins to).
        var dimLevel: Float = KeepAwakeController.dimLevel
        /// Also snapshot + zero every keyboard backlight for the session (restored on stop).
        var dimKeyboard: Bool = false
        /// The guard: once armed, ANY input (trackpad, mouse, keys) stops the session and locks the
        /// screen — lock first, then restore, so unlocked content never flashes.
        var lockOnStop: Bool = false
        /// The curtain (`keep-awake-agent-curtain`): once armed, input from a person or an untrusted app
        /// is SWALLOWED (an active event tap) while trusted apps' synthesized input passes, so agents
        /// keep working. The first swallowed input opens a Touch ID check: success ends the session
        /// (no lock); failure keeps the curtain up — or, with `lockOnStop`, locks the screen.
        var curtain: Bool = false

        /// Any guard at all (lock and/or curtain) — both run behind the curtain tap when it is available.
        var guarded: Bool { lockOnStop || curtain }
    }

    /// Why a stop fired. Only `.input` (the armed touch / the guard's monitor) may lock; every
    /// explicit or teardown path (re-fire toggle, menu bar, quit, will-sleep) never does (design D6).
    enum StopReason {
        case input
        case explicit
    }

    /// Injected effect seam. Defaults to `.live` (real DisplayServices + ProcessInfo + IOKit); the
    /// keyboard/lock/monitor entries default to inert no-ops so constructions without them still work.
    struct Effects {
        var activeDisplays: () -> [CGDirectDisplayID]
        var getBrightness: (CGDirectDisplayID) -> Float?
        var setBrightness: (CGDirectDisplayID, Float) -> Void
        /// Begin the no-sleep/no-lock activity; returns the opaque token to end later.
        var beginActivity: () -> NSObjectProtocol
        var endActivity: (NSObjectProtocol) -> Void
        /// Best-effort "poke" resetting the idle/lock timer (belt-and-suspenders on the heartbeat).
        var declareUserActive: () -> Void
        /// Backlight-controllable keyboards (empty when unavailable — the effect is skipped).
        var keyboardBacklightIDs: () -> [UInt64] = { [] }
        var getKeyboardBrightness: (UInt64) -> Float? = { _ in nil }
        var setKeyboardBrightness: (UInt64, Float) -> Void = { _, _ in }
        /// The guard's exit one-shot: lock the screen immediately.
        var lockScreen: () -> Void = {}
        /// Install a passive any-input monitor; the callback fires once per observed human input.
        /// Returns an opaque token for `endInputMonitoring` (nil = unavailable).
        var beginInputMonitoring: (@escaping () -> Void) -> Any? = { _ in nil }
        var endInputMonitoring: (Any) -> Void = { _ in }
        /// Install the curtain tap; the callback reports each swallowed input (a short description).
        /// nil = unavailable (no Accessibility) → the controller falls back to the passive monitor + lock.
        var beginCurtain: (@escaping (String) -> Void) -> Any? = { _ in nil }
        var endCurtain: (Any) -> Void = { _ in }
        /// Let the owner answer the visible password prompt (keys + clicks inside the prompt only).
        var setCurtainPassThrough: (Any, Bool) -> Void = { _, _ in }
        /// Start one owner check (Touch ID; password only when `allowPassword` and no biometrics).
        /// Returns whether it started and whether it needs input pass-through. Completion runs once.
        var authenticate: (_ allowPassword: Bool, _ completion: @escaping (GuardAuthResult) -> Void)
            -> (started: Bool, needsPassThrough: Bool) = { _, _ in (false, false) }
        var cancelAuthentication: () -> Void = {}
        /// The SILENT owner check (`keep-awake-silent-touch-id`): Touch ID listens with no prompt while
        /// the curtain is up. nil = unavailable (no Touch ID) → the controller uses the visible prompt.
        /// `passwordOnNoMatch` (Curtain mode): a wrong finger opens blind password entry inside the
        /// listener instead of reporting `.failed`.
        var beginListener: (_ passwordOnNoMatch: Bool, @escaping (SilentOwnerListener.Result) -> Void) -> Any? = { _, _ in nil }
        var endListener: (Any) -> Void = { _ in }
        /// A person touched the Mac: the listener takes focus now and shows the fingerprint icon.
        var attendListener: (Any) -> Void = { _ in }
        /// Pause / resume the listener (paused while the visible password prompt owns focus).
        var pauseListener: (Any, Bool) -> Void = { _, _ in }
        /// Run a block later on the main thread (Lock mode's silent deadline).
        var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            nonisolated(unsafe) let run = block   // always scheduled on, and run on, the main queue
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run() }
        }
        /// Start / stop the crash watchdog that locks the Mac if this process dies with the curtain up.
        var startWatchdog: () -> Bool = { false }
        var stopWatchdog: () -> Void = {}
        /// Guard events for the log + the user's hook: ("intrusion" | "auth-ok" | "auth-failed", detail).
        var notify: (String, String) -> Void = { _, _ in }
        var now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }

        static var live: Effects { live(policy: InputTrustPolicy.live(trustedBundleIDs: { ["ai.shift.vex.desktop"] }),
                                         hookCommand: { "" }) }

        /// The live effects over the user's trusted-apps list and intrusion hook (both read per use).
        static func live(policy: @escaping () -> InputTrustPolicy, hookCommand: @escaping () -> String) -> Effects {
            let poke = UserActivityPoke()
            let authenticator = MainActor.assumeIsolated { GuardAuthenticator() }
            let link = ListenerLink()
            return Effects(
                activeDisplays: { DisplayBrightness.activeDisplays() },
                getBrightness: { DisplayBrightness.get($0) },
                setBrightness: { DisplayBrightness.set($0, $1) },
                beginActivity: {
                    // `.userInitiated` already implies idle-system-sleep-disabled; add display sleep so
                    // the screen never sleeps (and therefore never idle-locks) while we hold this.
                    ProcessInfo.processInfo.beginActivity(
                        options: [.idleDisplaySleepDisabled, .userInitiated],
                        reason: "Keep Awake automation")
                },
                endActivity: { ProcessInfo.processInfo.endActivity($0) },
                declareUserActive: { poke.declare() },
                keyboardBacklightIDs: { KeyboardBrightness.keyboardIDs() },
                getKeyboardBrightness: { KeyboardBrightness.get($0) },
                setKeyboardBrightness: { KeyboardBrightness.set($0, $1) },
                lockScreen: { ScreenLocker.lock() },
                // The controller is @MainActor and only invokes these there; the monitor is too.
                beginInputMonitoring: { onInput in
                    MainActor.assumeIsolated { InputActivityMonitor(policy: policy, onInput: onInput) }
                },
                endInputMonitoring: { token in
                    MainActor.assumeIsolated { (token as? InputActivityMonitor)?.stop() }
                },
                beginCurtain: { onIntrusion in
                    MainActor.assumeIsolated {
                        let tap = CurtainEventTap(policy: policy) { type, origin in
                            onIntrusion("\(type.guardLogName) from \(origin)")
                        }
                        tap.onTrusted = { type, event in link.listener?.noteTrusted(type, event) ?? false }
                        link.tap = tap
                        return tap.start() ? tap : nil
                    }
                },
                endCurtain: { token in MainActor.assumeIsolated { (token as? CurtainEventTap)?.stop() } },
                setCurtainPassThrough: { token, on in
                    MainActor.assumeIsolated { (token as? CurtainEventTap)?.passThrough = on }
                },
                authenticate: { allowPassword, completion in
                    MainActor.assumeIsolated {
                        authenticator.authenticate(allowPassword: allowPassword,
                                                   timeoutSec: KeepAwakeController.authTimeout,
                                                   completion: completion)
                    }
                },
                cancelAuthentication: { MainActor.assumeIsolated { authenticator.cancel() } },
                beginListener: { passwordOnNoMatch, onResult in
                    MainActor.assumeIsolated {
                        guard SilentOwnerListener.available() else { return nil }
                        let l = SilentOwnerListener(passwordOnNoMatch: passwordOnNoMatch, onResult: onResult)
                        l.setKeyPassThrough = { on in link.tap?.ownPasswordEntry = on }
                        link.listener = l
                        l.start()
                        return l
                    }
                },
                endListener: { token in
                    MainActor.assumeIsolated {
                        (token as? SilentOwnerListener)?.stop()
                        link.listener = nil
                    }
                },
                attendListener: { token in MainActor.assumeIsolated { (token as? SilentOwnerListener)?.attend() } },
                pauseListener: { token, on in
                    MainActor.assumeIsolated { (token as? SilentOwnerListener)?.setPaused(on) }
                },
                startWatchdog: { CurtainWatchdog.start() },
                stopWatchdog: { CurtainWatchdog.stop() },
                notify: { event, detail in
                    GuardLog.write("\(event) \(detail)")
                    GuardHook.run(command: hookCommand(), event: event, detail: detail)
                })
        }
    }

    /// The trackpad-arming phase of an active session.
    private enum Arm {
        case awaitingEmpty   // active, waiting for the triggering gesture to fully lift (an empty frame)
        case armed           // active + armed: the next contact stops us
    }

    // `nonisolated`: immutable constants referenced from default-argument and default-initializer
    // expressions, which Swift evaluates in the CALLER's isolation — hence the "main actor-isolated
    // static property … from a nonisolated context" warnings (errors in Swift 6 mode).

    /// The default dim level (minimum). `DisplayServices` clamps to the panel's real floor.
    nonisolated static let dimLevel: Float = 0
    /// Heartbeat cadence: re-pin brightness + re-declare user activity.
    nonisolated static let heartbeatInterval: TimeInterval = 300
    /// How long one owner check may stay open before it counts as a failure.
    nonisolated static let authTimeout: TimeInterval = 20
    /// After a failed check behind a curtain (no lock), ignore further input this long so a resting
    /// palm can't re-open the prompt in a loop.
    nonisolated static let authCooldown: TimeInterval = 5

    /// Convert an item's optional 0…100 dim percent (nil = minimum) to a clamped 0…1 brightness fraction.
    nonisolated static func fraction(fromPercent percent: Double?) -> Float {
        Float(max(0, min(100, percent ?? 0)) / 100)
    }

    private let effects: Effects
    private let heartbeatInterval: TimeInterval

    /// Fired whenever `isActive` flips — wired to a menu-bar rebuild so the "Active / Stop" line tracks.
    var onActiveChanged: (() -> Void)?

    private(set) var isActive = false
    private var arm: Arm = .awaitingEmpty
    private var config = Config()
    private var savedBrightness: [CGDirectDisplayID: Float] = [:]
    private var savedKeyboard: [UInt64: Float] = [:]
    private var activityToken: NSObjectProtocol?
    private var inputMonitorToken: Any?
    private var curtainToken: Any?
    private var listenerToken: Any?
    /// Lock mode's silent deadline: bumped to invalidate a pending one.
    private var deadlineGeneration = 0
    private var deadlinePending = false
    private var watchdogRunning = false
    private var authInFlight = false
    private var intrusionNotified = false
    private var cooldownUntil: TimeInterval = 0

    /// Whether the curtain tap is up (a guarded, armed session with the tap available).
    var isCurtained: Bool { curtainToken != nil }
    private var heartbeat: Timer?

    init(effects: Effects = .live,
         heartbeatInterval: TimeInterval = KeepAwakeController.heartbeatInterval) {
        self.effects = effects
        self.heartbeatInterval = heartbeatInterval
    }

    // MARK: - Toggle / start / stop

    /// Fire semantics: start if inactive, stop if active (an explicit stop — never locks).
    func toggle(_ config: Config = Config()) { isActive ? stop(reason: .explicit) : start(config) }

    /// Convenience for the pre-guard call shape (tests, simple starts).
    func start(dimTo level: Float = KeepAwakeController.dimLevel) {
        start(Config(dimLevel: level))
    }

    func start(_ config: Config) {
        guard !isActive else { return }
        isActive = true
        arm = .awaitingEmpty
        self.config = config
        // Snapshot + dim every controllable display. A display whose brightness can't be read is left
        // untouched (nothing to restore) — never a failure (design D6).
        savedBrightness.removeAll()
        for display in effects.activeDisplays() {
            guard let current = effects.getBrightness(display) else { continue }
            savedBrightness[display] = current
            effects.setBrightness(display, config.dimLevel)
        }
        // The keyboard backlight is the same symmetric effect (snapshot → zero → restore); a keyboard
        // that can't be read is skipped exactly like an undimmable display.
        savedKeyboard.removeAll()
        if config.dimKeyboard {
            for keyboard in effects.keyboardBacklightIDs() {
                guard let current = effects.getKeyboardBrightness(keyboard) else { continue }
                savedKeyboard[keyboard] = current
                effects.setKeyboardBrightness(keyboard, 0)
            }
        }
        // Hold the no-sleep / no-lock assertion for the whole session.
        activityToken = effects.beginActivity()
        // Heartbeat — plain Foundation timer (NOT a SwiftUI animation, so no idle-CPU-spin landmine).
        heartbeat = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeatTick() }
        }
        heartbeat?.tolerance = 30   // a 5-minute heartbeat needn't force a precise wake on a dark screen
        onActiveChanged?()
    }

    /// Idempotent teardown: stop the heartbeat, remove the guard's monitor FIRST (so the lock's own
    /// event fallout can't re-enter), lock if this is a guarded input-path stop (BEFORE restore — the
    /// lock screen, not the unlocked desktop, is what fades in as brightness returns), restore every
    /// dimmed keyboard and display to its captured level, release the assertion exactly once. Safe
    /// (no-op) if already stopped.
    func stop(reason: StopReason = .explicit) {
        guard isActive else { return }
        isActive = false
        arm = .awaitingEmpty
        heartbeat?.invalidate()
        heartbeat = nil
        if let token = inputMonitorToken {
            effects.endInputMonitoring(token)
            inputMonitorToken = nil
        }
        if authInFlight {
            authInFlight = false
            effects.cancelAuthentication()
        }
        deadlineGeneration += 1
        deadlinePending = false
        // The listener goes before the lock: it may hand focus back to an app, which must happen
        // under the curtain (and, in Lock mode, before the lock screen comes up).
        if let token = listenerToken {
            effects.endListener(token)
            listenerToken = nil
        }
        // An input-path stop locks when the item asks for it — and ALWAYS when the curtain was wanted
        // but could not be installed (the passive fallback must fail closed, never leave the Mac open).
        if reason == .input, config.lockOnStop || (config.curtain && curtainToken == nil) {
            effects.lockScreen()
        }
        // The curtain comes down only AFTER the lock (so no input slips through in between).
        if let token = curtainToken {
            effects.endCurtain(token)
            curtainToken = nil
        }
        if watchdogRunning {
            effects.stopWatchdog()
            watchdogRunning = false
        }
        intrusionNotified = false
        cooldownUntil = 0
        for (keyboard, level) in savedKeyboard {
            effects.setKeyboardBrightness(keyboard, level)
        }
        savedKeyboard.removeAll()
        for (display, level) in savedBrightness {
            effects.setBrightness(display, level)
        }
        savedBrightness.removeAll()
        if let token = activityToken {
            effects.endActivity(token)
            activityToken = nil
        }
        onActiveChanged?()
    }

    // MARK: - Trackpad arming (non-consuming)

    /// Fed from the touch stream on every frame. Arms only after the triggering gesture fully lifts (an
    /// empty frame), so the trigger can't self-cancel; the next contact while armed stops us — an
    /// **input**-path stop, so a guarded session locks. Arming is also where the guard's any-input
    /// monitor is installed (so mouse/keys can't self-cancel the trigger either — nothing is monitored
    /// until the firing gesture has fully lifted). This is a pure side effect — the caller does NOT
    /// consume the frame, so a normal gesture still proceeds (post-lock it lands on the lock screen).
    func noteTouch(fingerCount: Int) {
        guard isActive else { return }
        switch arm {
        case .awaitingEmpty:
            if fingerCount == 0 {
                arm = .armed
                guard config.guarded else { return }
                // Preferred: the curtain (swallow + Touch ID). Fallback: the passive monitor + lock.
                if curtainToken == nil {
                    curtainToken = effects.beginCurtain { [weak self] detail in self?.intrusion(detail) }
                    if curtainToken != nil {
                        watchdogRunning = effects.startWatchdog()
                        listenerToken = effects.beginListener(config.curtain && !config.lockOnStop) { [weak self] r in
                            self?.listenerEnded(r)
                        }
                    }
                }
                if curtainToken == nil, inputMonitorToken == nil {
                    inputMonitorToken = effects.beginInputMonitoring { [weak self] in
                        self?.stop(reason: .input)
                    }
                }
            }
        case .armed:
            guard fingerCount > 0 else { return }
            // Behind the curtain a trackpad contact is an intrusion (owner check), not an instant stop:
            // a palm resting while the owner reaches for Touch ID must not lock the Mac.
            if curtainToken != nil { intrusion("trackpad contact (\(fingerCount))") } else { stop(reason: .input) }
        }
    }

    // MARK: - Curtain: intrusion → owner check

    /// A swallowed input (or a trackpad contact) behind the curtain. The first intrusion of a session
    /// is reported to the hook.
    /// - With the silent listener: NOTHING visible happens beyond the fingerprint icon — the listener
    ///   takes focus so the owner's finger ends the session. Lock mode also starts a silent deadline:
    ///   no owner finger within `authTimeout` → lock.
    /// - Without it (no Touch ID): ONE visible owner check at a time (the pre-silent behaviour).
    func intrusion(_ detail: String) {
        guard isActive, curtainToken != nil, !authInFlight, effects.now() >= cooldownUntil else { return }
        if !intrusionNotified {
            intrusionNotified = true
            effects.notify("intrusion", detail)
        }
        if let listener = listenerToken {
            effects.attendListener(listener)
            if config.lockOnStop, !deadlinePending {
                deadlinePending = true
                let generation = deadlineGeneration
                effects.after(Self.authTimeout) { [weak self] in
                    guard let self, self.isActive, self.deadlineGeneration == generation else { return }
                    self.effects.notify("auth-failed", "no owner finger within \(Int(Self.authTimeout)) s")
                    self.stop(reason: .input)
                }
            }
            return
        }
        openVisibleCheck()
    }

    /// The visible owner check: Lock mode = Touch ID only; Curtain mode = Touch ID or password.
    private func openVisibleCheck() {
        guard isActive, let token = curtainToken, !authInFlight else { return }
        authInFlight = true
        // Lock mode never needs the password path: on failure the real lock screen takes over.
        let allowPassword = config.curtain && !config.lockOnStop
        let r = effects.authenticate(allowPassword) { [weak self] result in self?.authEnded(result) }
        if !r.started {
            authInFlight = false
            authEnded(.failure)
            return
        }
        if r.needsPassThrough { effects.setCurtainPassThrough(token, true) }
    }

    /// The silent listener's answer: the owner's finger ends the session; an unrecognized finger opens
    /// the visible prompt WITH a password option (Curtain) or locks (Lock).
    private func listenerEnded(_ result: SilentOwnerListener.Result) {
        guard isActive, !authInFlight else { return }
        switch result {
        case .success:
            effects.notify("auth-ok", "touch id (silent)")
            stop(reason: .explicit)
        case .failed:
            effects.notify("auth-failed", "finger not recognized")
            if config.lockOnStop {
                stop(reason: .input)
            } else {
                if let l = listenerToken { effects.pauseListener(l, true) }
                openVisibleCheck()
            }
        }
    }

    private func authEnded(_ result: GuardAuthResult) {
        guard isActive else { return }
        authInFlight = false
        if let token = curtainToken { effects.setCurtainPassThrough(token, false) }
        if result == .failure, !config.lockOnStop, let l = listenerToken { effects.pauseListener(l, false) }
        effects.notify(result == .success ? "auth-ok" : "auth-failed", "")
        switch result {
        case .success:
            stop(reason: .explicit)          // the owner: restore, never lock
        case .failure:
            if config.lockOnStop {
                stop(reason: .input)         // lock first, then restore (D3)
            } else {
                cooldownUntil = effects.now() + Self.authCooldown   // stay curtained
            }
        }
    }

    // MARK: - Heartbeat

    /// Re-pin the displays we dimmed (defeat another app / auto-brightness raising them) and the
    /// keyboards we darkened (defeat auto-illumination), and re-declare user activity. Only what was
    /// snapshotted at start is touched. `internal` so the tests can drive a tick deterministically
    /// without waiting on the real timer.
    func heartbeatTick() {
        guard isActive else { return }
        for display in savedBrightness.keys {
            effects.setBrightness(display, config.dimLevel)
        }
        for keyboard in savedKeyboard.keys {
            effects.setKeyboardBrightness(keyboard, 0)
        }
        effects.declareUserActive()
    }
}

/// Holds one reused `IOPMAssertionID` across heartbeat pokes. `IOPMAssertionDeclareUserActivity`
/// declares a short, auto-releasing burst of "user is active", resetting the idle/lock timer; reusing
/// the id updates the same assertion rather than churning new ones.
private final class UserActivityPoke {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    func declare() {
        _ = IOPMAssertionDeclareUserActivity(
            "ThreeFingerSwitcher Keep Awake" as CFString,
            kIOPMUserActiveLocal,
            &assertionID)
    }
}

/// Lets the live curtain tap reach the live silent listener (both are created inside `Effects.live`
/// closures; the controller only holds opaque tokens).
private final class ListenerLink: @unchecked Sendable {
    weak var listener: SilentOwnerListener?
    weak var tap: CurtainEventTap?
}
