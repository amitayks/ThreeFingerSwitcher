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

        static var live: Effects {
            let poke = UserActivityPoke()
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
                    MainActor.assumeIsolated { InputActivityMonitor(onInput: onInput) }
                },
                endInputMonitoring: { token in
                    MainActor.assumeIsolated { (token as? InputActivityMonitor)?.stop() }
                })
        }
    }

    /// The trackpad-arming phase of an active session.
    private enum Arm {
        case awaitingEmpty   // active, waiting for the triggering gesture to fully lift (an empty frame)
        case armed           // active + armed: the next contact stops us
    }

    /// The default dim level (minimum). `DisplayServices` clamps to the panel's real floor.
    static let dimLevel: Float = 0
    /// Heartbeat cadence: re-pin brightness + re-declare user activity.
    static let heartbeatInterval: TimeInterval = 300

    /// Convert an item's optional 0…100 dim percent (nil = minimum) to a clamped 0…1 brightness fraction.
    static func fraction(fromPercent percent: Double?) -> Float {
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
        if reason == .input, config.lockOnStop {
            effects.lockScreen()
        }
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
                if config.lockOnStop, inputMonitorToken == nil {
                    inputMonitorToken = effects.beginInputMonitoring { [weak self] in
                        self?.stop(reason: .input)
                    }
                }
            }
        case .armed:
            if fingerCount > 0 { stop(reason: .input) }
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
