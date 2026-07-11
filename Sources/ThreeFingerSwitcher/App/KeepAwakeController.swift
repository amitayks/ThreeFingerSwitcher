import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// The stateful owner of the **Keep Awake** automation (`automations` capability). Unlike every
/// one-shot launcher action, this is a *mode you enter and leave*: firing the `.automation(.keepAwake)`
/// item TOGGLES it (see `LaunchService.onAutomation` → `AppCoordinator`).
///
/// While active it (design D2, "awake-but-dark"):
///   • dims **every** active display to minimum (snapshotting each first, restoring on stop),
///   • holds a `ProcessInfo.beginActivity` assertion that blocks system sleep, display sleep, and thus
///     the idle screen lock — public API, **no new permission** (the `ModelManager` precedent),
///   • runs a ~5-minute heartbeat that re-pins brightness and re-declares user activity as a safety net.
///
/// It stops on the **next trackpad touch after the triggering gesture lifts** (design D3): after start
/// it waits for one empty frame (the firing gesture released) to ARM, then the next contact stops it —
/// so the trigger can never self-cancel. Teardown is idempotent and also runs on quit / will-sleep so a
/// dimmed-to-black screen and a held assertion are never stranded (design D4).
///
/// The side effects are behind an injectable `Effects` seam so the whole start→arm→stop lifecycle is
/// unit-tested with recording fakes; the live power/brightness behavior is user-run-verified.
@MainActor
final class KeepAwakeController {
    /// Injected effect seam. Defaults to `.live` (real DisplayServices + ProcessInfo + IOKit).
    struct Effects {
        var activeDisplays: () -> [CGDirectDisplayID]
        var getBrightness: (CGDirectDisplayID) -> Float?
        var setBrightness: (CGDirectDisplayID, Float) -> Void
        /// Begin the no-sleep/no-lock activity; returns the opaque token to end later.
        var beginActivity: () -> NSObjectProtocol
        var endActivity: (NSObjectProtocol) -> Void
        /// Best-effort "poke" resetting the idle/lock timer (belt-and-suspenders on the heartbeat).
        var declareUserActive: () -> Void

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
                declareUserActive: { poke.declare() })
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
    private var savedBrightness: [CGDirectDisplayID: Float] = [:]
    private var activityToken: NSObjectProtocol?
    private var heartbeat: Timer?
    /// The 0…1 level the current session dims to (and the heartbeat re-pins to).
    private var activeDimLevel: Float = KeepAwakeController.dimLevel

    init(effects: Effects = .live,
         heartbeatInterval: TimeInterval = KeepAwakeController.heartbeatInterval) {
        self.effects = effects
        self.heartbeatInterval = heartbeatInterval
    }

    // MARK: - Toggle / start / stop

    /// Fire semantics: start if inactive, stop if active. `dimTo` (0…1) is the level to dim to on start.
    func toggle(dimTo level: Float = KeepAwakeController.dimLevel) { isActive ? stop() : start(dimTo: level) }

    func start(dimTo level: Float = KeepAwakeController.dimLevel) {
        guard !isActive else { return }
        isActive = true
        arm = .awaitingEmpty
        activeDimLevel = level
        // Snapshot + dim every controllable display. A display whose brightness can't be read is left
        // untouched (nothing to restore) — never a failure (design D6).
        savedBrightness.removeAll()
        for display in effects.activeDisplays() {
            guard let current = effects.getBrightness(display) else { continue }
            savedBrightness[display] = current
            effects.setBrightness(display, level)
        }
        // Hold the no-sleep / no-lock assertion for the whole session.
        activityToken = effects.beginActivity()
        // Heartbeat — plain Foundation timer (NOT a SwiftUI animation, so no idle-CPU-spin landmine).
        heartbeat = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeatTick() }
        }
        onActiveChanged?()
    }

    /// Idempotent teardown: stop the heartbeat, release the assertion exactly once, restore every
    /// dimmed display to its captured brightness. Safe (no-op) if already stopped.
    func stop() {
        guard isActive else { return }
        isActive = false
        arm = .awaitingEmpty
        heartbeat?.invalidate()
        heartbeat = nil
        if let token = activityToken {
            effects.endActivity(token)
            activityToken = nil
        }
        for (display, level) in savedBrightness {
            effects.setBrightness(display, level)
        }
        savedBrightness.removeAll()
        onActiveChanged?()
    }

    // MARK: - Trackpad arming (non-consuming)

    /// Fed from the touch stream on every frame. Arms only after the triggering gesture fully lifts (an
    /// empty frame), so the trigger can't self-cancel; the next contact while armed stops us. This is a
    /// pure side effect — the caller does NOT consume the frame, so a normal gesture still proceeds.
    func noteTouch(fingerCount: Int) {
        guard isActive else { return }
        switch arm {
        case .awaitingEmpty:
            if fingerCount == 0 { arm = .armed }
        case .armed:
            if fingerCount > 0 { stop() }
        }
    }

    // MARK: - Heartbeat

    /// Re-pin the displays we dimmed to minimum (defeat another app / auto-brightness raising them) and
    /// re-declare user activity. Only the displays snapshotted at start are touched. `internal` so the
    /// tests can drive a tick deterministically without waiting on the real timer.
    func heartbeatTick() {
        guard isActive else { return }
        for display in savedBrightness.keys {
            effects.setBrightness(display, activeDimLevel)
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
