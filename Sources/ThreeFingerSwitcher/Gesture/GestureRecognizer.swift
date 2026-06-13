import Foundation
import CoreGraphics

/// Semantic events the recognizer emits. The controller owns the window list and applies
/// these (it knows item count, so wrap/clamp lives there).
@MainActor
protocol GestureRecognizerDelegate: AnyObject {
    /// Horizontal scrub crossed the activation threshold; show the switcher.
    func gestureDidActivate()
    /// Move the selection by one window (+1 next / -1 previous), already direction-adjusted.
    func gestureDidStep(_ direction: Int)
    /// Move the selection by one Space-row (+1 / -1), already direction-adjusted. Only emitted
    /// after activation (a fresh vertical gesture is left to the OS).
    func gestureDidStepRow(_ direction: Int)
    /// A fresh three-finger vertical swipe (no horizontal activation) while the app owns the
    /// vertical gesture: trigger the OS overview ourselves. `up` = Mission Control, down = App Exposé.
    /// Emitted once per gesture, only when row switching is active (the OS gesture is freed); when
    /// inactive the recognizer yields vertical to the OS exactly as before.
    func gestureDidTriggerMissionControl(up: Bool)
    /// Fingers lifted after activation; commit the current selection.
    func gestureDidCommit()
    /// Gesture ended without committing (vertical yield, below threshold, or 4th finger).
    func gestureDidCancel()

    // MARK: Four-finger launcher intents (latched at gesture start when `launcherEnabled`).
    // Default no-op implementations are provided below so conformers that don't use the launcher
    // compile unchanged.

    /// Four-finger horizontal scrub crossed the activation threshold; show the launcher.
    func launcherDidActivate()
    /// Move the launcher selection by one item (+1 / -1), already direction-adjusted.
    func launcherDidStepItem(_ direction: Int)
    /// Move the launcher selection by one context band (+1 / -1), already direction-adjusted.
    func launcherDidStepContext(_ direction: Int)
    /// Fingers lifted after launcher activation; the controller fires the armed item or dismisses.
    func launcherDidEnd()
    /// Launcher gesture aborted (extra finger / engine reset); dismiss without firing.
    func launcherDidCancel()
    /// The controlling contact's held-edge state during launcher navigation, per axis: `dx`/`dy` are
    /// each −1 / 0 / +1 (`dx +1` = right edge, `dy +1` = top edge). Emitted whenever the edge state
    /// changes; `(0, 0)` means no edge. Drives edge-triggered auto-repeat of horizontal item/band
    /// stepping and vertical row stepping.
    func launcherEdgeChanged(dx: Int, dy: Int)
    /// Whether the launcher cursor is on the band list (the left title column, where vertical travel
    /// switches bands). Lets the recognizer apply the coarser context-step to the VERTICAL band switch
    /// and the finer item-step to in-grid item movement — so the two can be tuned independently.
    /// Defaults to false.
    func launcherFocusIsOnBandList() -> Bool
    /// While the launcher's AI preview canvas is open, a fresh four-finger swipe RESOLVES it instead of
    /// navigating: `dx != 0` is a horizontal swipe (discard); `dy` is vertical (`+1` up, `-1` down) — a
    /// DOWN swipe applies the result ("bring it into the document"). Emitted once per gesture, only
    /// while `launcherCanvasResolutionActive`.
    func launcherCanvasResolve(dx: Int, dy: Int)

    // MARK: Files-drill intents (emitted only while `filesDrillActive`; the controller drives entry/exit).
    // The recognizer emits pure intents — directory navigation, preview, search-field focus (an up-step
    // while already at the top of the list), arm, and fire all live in the model/controller, not here.
    // Default no-op implementations are provided below so non-Files conformers compile unchanged.

    /// While the Files column navigator is open, horizontal travel past one item-step steps the depth
    /// (descend / ascend), already direction-adjusted (`+1` / `-1`). The controller maps it to descend
    /// the current folder / ascend to the parent.
    func filesDepth(_ direction: Int)
    /// Vertical travel past one item-step moves the highlighted entry, already direction-adjusted
    /// (`+1` / `-1`). An up-step while already clamped at the top of the list is interpreted by the
    /// controller/model as focus-search; the recognizer just keeps emitting steps.
    func filesHighlight(_ direction: Int)
    /// The resolving lift with no added finger: open the highlighted entry (default action). One-shot.
    func filesOpen()
    /// The resolving lift after a relative +1 finger was added: Open-With the highlighted entry. One-shot.
    func filesOpenWith()
    /// A fresh deliberate four-finger horizontal swipe-away while drilled: discard (defuse a held open /
    /// dismiss the navigator). One-shot.
    func filesDiscard()

    // MARK: Player transport intents (emitted only while `playerActive`; the controller drives entry/exit).
    // The built-in media player owns the trackpad while open — a third sustained modal sub-state mirroring
    // the Files drill, but PERSISTENT (a lift ends one scrub, it does not leave the player). Default no-op
    // implementations are provided below so non-player conformers compile unchanged.

    /// Two-finger horizontal step (`+1` / `-1`, direction-adjusted): seek one step (the controller scales
    /// it to seconds + auto-repeats off the held-zone signal). Fast-forward / rewind.
    func playerSeek(_ direction: Int)
    /// Two-finger vertical step (`+1` / `-1`, direction-adjusted): change volume one step — OR, while the
    /// action menu is open, move the menu highlight (the controller routes it).
    func playerVolume(_ direction: Int)
    /// A two-finger tap (contact + lift with no navigation excursion): toggle play/pause.
    func playerTogglePlayPause()
    /// A relative +1 finger (one more than the navigation baseline): raise the action menu.
    func playerActionMenu()
    /// A resolving lift while the action menu is open: select the highlighted row (the Open-With pattern).
    func playerSelectMenuItem()
    /// A four-finger gesture: dismiss the player (persist + leave). One-shot.
    func playerDismiss()
    /// The per-axis held-in-zone sign (−1 / 0 / +1) for the player, emitted when it changes so the
    /// controller drives eased auto-repeat. BOTH axes auto-repeat (seek and volume), unlike the Files/
    /// Clipboard surfaces that suppress horizontal auto-repeat.
    func playerHeldZoneChanged(dx: Int, dy: Int)
}

extension GestureRecognizerDelegate {
    func launcherDidActivate() {}
    func launcherDidStepItem(_ direction: Int) {}
    func launcherDidStepContext(_ direction: Int) {}
    func launcherDidEnd() {}
    func launcherDidCancel() {}
    func launcherEdgeChanged(dx: Int, dy: Int) {}
    func launcherFocusIsOnBandList() -> Bool { false }
    func launcherCanvasResolve(dx: Int, dy: Int) {}
    func filesDepth(_ direction: Int) {}
    func filesHighlight(_ direction: Int) {}
    func filesOpen() {}
    func filesOpenWith() {}
    func filesDiscard() {}
    func playerSeek(_ direction: Int) {}
    func playerVolume(_ direction: Int) {}
    func playerTogglePlayPause() {}
    func playerActionMenu() {}
    func playerSelectMenuItem() {}
    func playerDismiss() {}
    func playerHeldZoneChanged(dx: Int, dy: Int) {}
}

/// Multi-finger scrub state machine. The active finger count is **latched at gesture start**:
/// a gesture beginning with three fingers is a window-switcher gesture; a gesture beginning with
/// four fingers (when `launcherEnabled`) is a launcher gesture. The latched mode governs the whole
/// gesture — there is no mid-gesture morph, and when the launcher is off the four-finger path is
/// never taken, so three-finger behavior is byte-identical to before.
///
///   idle ──(3 fingers)──▶ candidate ──┬─(vertical dominates)─▶ yielding ──(lift)─▶ idle
///                                      └─(horizontal dominates)▶ horizontal
///   horizontal ──(|Δx| ≥ activation)─▶ active (overlay shown), steps emitted
///   active ──(lift)─▶ commit ; horizontal-but-not-active ──(lift)─▶ cancel
///   switcher ──(4th finger)─▶ cancel  (only when the launcher is off)
///   idle ──(4 fingers, launcher on)──▶ launcher: ──(|Δx| ≥ activation)─▶ active; steps; <2 fingers → end
///
/// The launcher gesture is **latched** at begin and lives while ≥2 contacts remain: once a
/// four-finger swipe opens it, the user can relax to two (or three) fingers and keep navigating.
/// The latched mode is never re-evaluated, so the transient three-finger count during a four→two
/// lift never routes to the switcher and never cancels; the step origin is re-baselined on every
/// contact-count change so the centroid shift from a leaving finger emits no step. It ends when the
/// contact count drops below two. Holding four fingers the whole time behaves exactly as before.
@MainActor
final class GestureRecognizer {
    weak var delegate: GestureRecognizerDelegate?

    private let settings: AppSettings

    /// Whether vertical Space-row stepping is active. Off by default; the coordinator sets it true
    /// only when the Space-row switching opt-in is *effective* — i.e. enabled AND the native
    /// three-finger vertical gesture has actually been relocated to four fingers (so the OS no
    /// longer steals the vertical swipe). When false, vertical motion is left entirely to the OS.
    var rowSwitchingEnabled = false

    /// Whether four-finger launcher gestures are recognized. Off by default; the coordinator sets it
    /// true only when the launcher opt-in is *effective* (enabled AND the native four-finger swipes
    /// have actually been freed). When false, four fingers behave exactly as before.
    var launcherEnabled = false

    /// While true (the launcher's AI preview canvas is open), a fresh four-finger swipe is interpreted
    /// as a one-shot canvas RESOLUTION (horizontal = discard, down = apply) via `launcherCanvasResolve`,
    /// bypassing the normal launcher/switcher latch. The coordinator sets it from the canvas state.
    var launcherCanvasResolutionActive = false
    private var canvasResStarted = false
    private var canvasResResolved = false
    private var canvasResStart: CGPoint = .zero

    /// While true (the Files column navigator is open), every frame routes to `trackFilesDrill` and the
    /// normal finger-count latch is bypassed — a fresh contact during the drill never opens the switcher
    /// or a second launcher. The controller flips it from the navigator's open/close state (mirroring
    /// `launcherCanvasResolutionActive`). Setting it `true` re-seeds a fresh drill session; while `false`
    /// (the default + all non-Files use) everything below is byte-identical to before.
    var filesDrillActive = false {
        didSet { if filesDrillActive && !oldValue { resetDrill() } }
    }
    /// Whether the current drill session has seeded its baseline yet (a fresh contact seeds it). Cleared
    /// on entry and on a true lift so the next contact re-seeds the origin.
    private var drillStarted = false
    /// Set once the session has resolved (open / open-with / discard). The resolution is **one-shot** for
    /// the whole session: while set, no further intent is emitted, so a stray re-lift is a no-op. Cleared
    /// only when the controller re-enters the sub-state.
    private var drillResolved = false
    /// Set once a relative +1 finger (a contact above the current relaxed baseline) is seen, so the
    /// resolving lift emits Open-With instead of a plain Open. Latched for the session.
    private var pendingOpenWith = false
    /// Relaxed contact baseline of the drill, re-baselined on every contact-count change (the gesture
    /// lives while ≥2 remain, so the user may relax fingers). A count rising ABOVE this is the relative
    /// +1 Open-With morph (D4) — not an absolute three.
    private var drillContacts = 0
    /// Reference origin for the drill, re-baselined (with the accumulators cleared) on every contact-count
    /// change so a leaving or landing finger's centroid shift emits no spurious step.
    private var drillStart = CGPoint.zero
    private var drillLast = CGPoint.zero
    private var drillAccumX: CGFloat = 0   // horizontal → depth steps
    private var drillAccumY: CGFloat = 0   // vertical → highlight steps

    /// While true (the built-in media player is open), every frame routes to `trackPlayer` and the normal
    /// finger-count latch is bypassed — a fresh contact during playback never opens the switcher or the
    /// launcher (so a three-finger count is the player's action menu, NOT the window switcher). The player
    /// controller flips it from the player's open/close state (mirroring `filesDrillActive`). Setting it
    /// `true` seeds a fresh session; while `false` (the default + all non-player use) everything is
    /// byte-identical to before.
    var playerActive = false {
        didSet { if playerActive && !oldValue { resetPlayer() } }
    }
    /// Set by the controller while the player's action menu is open: a resolving lift then SELECTS the
    /// highlighted row (the Open-With scrubbable-picker pattern) and `playerVolume` steps are the menu's
    /// (the controller routes them), rather than a tap toggling play/pause or volume changing.
    var playerMenuOpen = false
    /// Whether the current player scrub session has seeded its baseline yet (a fresh contact seeds it).
    private var playerStarted = false
    /// Relaxed contact baseline of the player scrub, re-baselined on every contact-count change. A count
    /// rising to baseline+1 is the action-menu morph; baseline+2 (or ≥4) dismisses.
    private var playerContacts = 0
    /// Whether the current contact session moved past the axis-detect threshold (so a lift is a scrub-end,
    /// not a tap). Reset when a fresh contact seeds. A tap = contact + lift with no movement → play/pause.
    private var playerMoved = false
    /// The centroid where the current player contact session seeded (for the tap-vs-scrub test).
    private var playerSeedCentroid = CGPoint.zero
    /// Player held-in-zone state per axis (−1 / 0 / +1), kept separate from the launcher/files `edgeDX/DY`.
    private var playerEdgeDX = 0
    private var playerEdgeDY = 0
    /// The anchored-positional navigator for the player's transport (change `positional-navigation`, D1).
    /// Same model as the launcher/files; BOTH axes auto-repeat (seek + volume). Re-anchored on entry /
    /// contact-count change; rebuilt from settings when a fresh session seeds.
    private var playerNav = PositionalNavigator(footprintFactor: 1.2, fallbackScale: 0.12,
                                                inner: 0.22, outer: 0.5)

    private enum Axis { case undetermined, horizontal, vertical }
    private enum State { case idle, tracking }
    private enum Mode { case switcher, launcher }

    private var state: State = .idle
    private var mode: Mode = .switcher
    private var axis: Axis = .undetermined
    private var activated = false
    /// One-shot guard so a fresh vertical swipe triggers Mission Control / App Exposé only once.
    private var triggeredMissionControl = false
    /// Consecutive frames seen below the required finger count (to debounce edge flicker vs. a
    /// real lift). A true lift reports 0 fingers immediately; an edge flicker dips to 1–2 briefly.
    private var belowTargetFrames = 0
    /// Live contact count of the latched launcher gesture, used to detect contact-count changes so
    /// the step origin can be re-baselined (the centroid shifts as fingers leave). Seeded at begin.
    private var launcherContacts = 0
    /// Held-in-zone state for auto-repeat, per axis (−1 / 0 / +1): `+1` = offset held beyond the outer
    /// threshold on the high side (right / up), `−1` = low side. Emitted to the delegate (still via
    /// `launcherEdgeChanged`, repurposed) when either changes; the controller drives the eased repeat
    /// off it. Replaces the old physical-trackpad-edge detection (change `positional-navigation`, D3).
    private var edgeDX = 0
    private var edgeDY = 0
    /// The anchored-positional navigator for the launcher's post-activation navigation (change
    /// `positional-navigation`, D1). (Re)anchored at activation and on every contact-count change; fed
    /// the centroid each frame to yield item/context steps + held-zone signs. Rebuilt from settings at
    /// `beginLauncher` so a tunable change between opens applies on the next gesture.
    private var launcherNav = PositionalNavigator(footprintFactor: 1.2, fallbackScale: 0.12,
                                                  inner: 0.22, outer: 0.5)
    /// The anchored-positional navigator for the Files drill (change `positional-navigation`, D1). Same
    /// model as the launcher: out-and-back = one step, held = auto-repeat. Horizontal (depth) is emitted
    /// as a deliberate discrete step with NO auto-repeat (descend/ascend must settle); vertical (highlight)
    /// out-and-backs and auto-repeats via the held-zone signal. Re-anchored on entry / contact-count change.
    private var filesNav = PositionalNavigator(footprintFactor: 1.2, fallbackScale: 0.12,
                                               inner: 0.22, outer: 0.5)
    /// Live contact count of the switcher gesture *after activation*, used the same way as
    /// `launcherContacts`: once the overlay is up the user may relax three fingers to two, and the
    /// centroid shifts as the finger leaves — so on a count change we re-baseline the step origin.
    private var switcherContacts = 0

    private var startCentroid = CGPoint.zero
    private var lastCentroid = CGPoint.zero
    private var stepAccumulator: CGFloat = 0    // horizontal → window/item steps
    private var stepAccumulatorY: CGFloat = 0   // vertical → Space-row/context steps (post-activation)

    /// Small movement needed before we attempt to decide the axis (normalized).
    private let axisDetectThreshold: CGFloat = 0.012

    /// Deliberate vertical travel (normalized) before a fresh vertical swipe triggers Mission
    /// Control / App Exposé — larger than axis detection so it isn't twitchy.
    private let missionControlThreshold: CGFloat = 0.10

    /// Deliberate travel (normalized) before a fresh TWO-finger swipe resolves the AI canvas (change
    /// `positional-navigation`, D5). Deliberately **larger than incidental two-finger scrolling** so
    /// reading/scrolling the canvas is never mistaken for a commit/discard.
    private let canvasResolveThreshold: CGFloat = 0.12

    init(settings: AppSettings) {
        self.settings = settings
    }

    func feed(_ frame: TouchFrame) {
        // While the launcher's AI preview canvas is open, a fresh four-finger swipe RESOLVES it
        // (horizontal = discard, down = apply) — bypassing the normal launcher/switcher latch. When the
        // flag is off (the default + all normal use), everything below is byte-identical to before.
        if launcherCanvasResolutionActive {
            trackCanvasResolution(frame)
            return
        }
        // While the Files column navigator is open, route every frame to the sustained drill tracker
        // BEFORE the idle re-latch below, so a fresh contact during drill-in never opens the switcher or
        // a second launcher on top of the navigator. Off by default → byte-identical to before.
        if filesDrillActive {
            trackFilesDrill(frame)
            return
        }
        // While the built-in player is open it OWNS the trackpad: every frame routes to the player
        // tracker before the idle re-latch, so a fresh contact during playback never opens the switcher
        // (a three-finger count is the player's action menu) or the launcher. Off by default → unchanged.
        if playerActive {
            trackPlayer(frame)
            return
        }
        let switcherTarget = settings.requireExactlyThree ? (frame.fingerCount == 3) : (frame.fingerCount >= 3)

        switch state {
        case .idle:
            // A four-finger start latches the launcher (when enabled); otherwise three fingers latch
            // the switcher. When the launcher is off this falls straight through to the switcher
            // path, so behavior is byte-identical to before.
            if launcherEnabled && frame.fingerCount == 4 {
                mode = .launcher
                beginLauncher(frame)
            } else if switcherTarget {
                mode = .switcher
                begin(frame)
            }
            // else: ignore (0/1/2 fingers, or vertical handled by OS anyway)

        case .tracking:
            switch mode {
            case .switcher: trackSwitcher(frame)
            case .launcher: trackLauncher(frame)
            }
        }
    }

    /// Abort any in-flight gesture (e.g. when the engine stops).
    func reset() {
        guard state == .tracking else { return }
        switch mode {
        case .switcher: cancel()
        case .launcher: cancelLauncher()
        }
    }

    /// One-shot canvas-resolution tracking (see `launcherCanvasResolutionActive`). A fresh **two-finger**
    /// swipe past `canvasResolveThreshold` reports a single `launcherCanvasResolve`: vertical-dominant →
    /// `dy` (`+1` up, `-1` down; down applies, up is ignored upstream), else horizontal → `dx` (discard).
    /// Two-finger resolution (change `positional-navigation`, D5) aligns the grammar — 4 fingers open /
    /// dismiss the platform, 2 fingers act within it — and the threshold sits ABOVE incidental scrolling so
    /// reading the canvas never resolves it. Runs INSTEAD of the normal state machine while the canvas is
    /// open, so it never opens the launcher or switcher; it self-resets on lift.
    private func trackCanvasResolution(_ frame: TouchFrame) {
        let count = frame.fingerCount
        if count == 0 {                       // lift → ready for the next resolution gesture
            canvasResStarted = false
            canvasResResolved = false
            return
        }
        if !canvasResStarted {
            guard count >= 2 else { return }  // require a fresh (≥) two-finger contact to begin
            canvasResStarted = true
            canvasResResolved = false
            canvasResStart = frame.centroid
            return
        }
        guard !canvasResResolved, count >= 2 else { return }
        let dx = frame.centroid.x - canvasResStart.x
        let dy = frame.centroid.y - canvasResStart.y
        let threshold = canvasResolveThreshold
        guard abs(dx) >= threshold || abs(dy) >= threshold else { return }
        canvasResResolved = true
        let ratio = CGFloat(settings.axisLockRatio)
        if abs(dy) >= ratio * abs(dx) {
            delegate?.launcherCanvasResolve(dx: 0, dy: dy > 0 ? 1 : -1)   // dy>0 = up, dy<0 = down
        } else {
            delegate?.launcherCanvasResolve(dx: dx > 0 ? 1 : -1, dy: 0)
        }
    }

    // MARK: - Switcher (three-finger; relaxes to two after activation)

    private func trackSwitcher(_ frame: TouchFrame) {
        let count = frame.fingerCount
        let tooMany = settings.requireExactlyThree ? (count > 3) : false

        // A 4th finger cancels exactly as before (only meaningful under requireExactlyThree); this
        // ceiling rule is unchanged in both phases — relaxation only ever lowers the floor to two.
        if tooMany {
            cancel()                      // a 4th finger landed
            return
        }

        guard activated else {
            // Pre-activation: unchanged three-finger trigger. The overlay isn't up yet, so the count
            // requirement is the original one and dropping below it cancels (a two-finger contact can
            // never trigger the switcher).
            let target = settings.requireExactlyThree ? (count == 3) : (count >= 3)
            if target {
                belowTargetFrames = 0
                update(frame)             // still scrubbing toward activation
            } else {
                // Below the required count: a real lift reports 0 fingers; an edge flicker dips
                // to 1–2 for a frame or two. Only end on a true lift or a sustained drop, so
                // swiping toward the trackpad edge doesn't prematurely commit/close.
                belowTargetFrames += 1
                if count == 0 || belowTargetFrames >= 2 {
                    end()
                }
                // otherwise ignore this frame and wait for the 3rd finger to return
            }
            return
        }

        // Post-activation: the overlay is up, so the user may relax three fingers to two and keep
        // navigating. The gesture lives while ≥2 contacts remain (the launcher's proven latch). On
        // any contact-count change the centroid shifts as a finger leaves, so re-baseline the step
        // origin and clear carry — only movement *after* the new baseline advances the selection.
        if count >= 2 {
            belowTargetFrames = 0
            if count != switcherContacts {
                switcherContacts = count
                startCentroid = frame.centroid
                lastCentroid = frame.centroid
                stepAccumulator = 0
                stepAccumulatorY = 0
            }
            update(frame)
        } else {
            // Below two contacts ("lift"): a real lift reports 0 immediately; an edge flicker dips to
            // 1 for a frame or two. End on a true lift or a sustained drop, then `end()` commits the
            // highlighted window (activated is true here).
            belowTargetFrames += 1
            if count == 0 || belowTargetFrames >= 2 {
                end()
            }
        }
    }

    private func begin(_ frame: TouchFrame) {
        state = .tracking
        axis = .undetermined
        activated = false
        startCentroid = frame.centroid
        lastCentroid = frame.centroid
        stepAccumulator = 0
        stepAccumulatorY = 0
        belowTargetFrames = 0
        triggeredMissionControl = false
        switcherContacts = frame.fingerCount   // 3 at begin; tracked so a post-activation drop re-baselines
    }

    private func update(_ frame: TouchFrame) {
        let c = frame.centroid
        let dx = c.x - startCentroid.x
        let dy = c.y - startCentroid.y

        if axis == .undetermined {
            let ratio = CGFloat(settings.axisLockRatio)
            if abs(dx) >= axisDetectThreshold || abs(dy) >= axisDetectThreshold {
                if abs(dx) >= ratio * abs(dy) {
                    axis = .horizontal
                } else if abs(dy) >= ratio * abs(dx) {
                    axis = .vertical            // let the OS own Mission Control / App Exposé
                }
                // otherwise diagonal-ish: stay undetermined until one axis dominates
            }
        }

        guard axis == .horizontal else {
            // Vertical or undetermined. When we own the vertical gesture (the OS three-finger
            // vertical swipe is freed to a scroll), a fresh vertical swipe should still open
            // Mission Control / App Exposé — so we synthesize it ourselves, once, after a
            // deliberate vertical travel. When we don't own it, yield to the OS exactly as before.
            if axis == .vertical, rowSwitchingEnabled, !triggeredMissionControl {
                let dy = c.y - startCentroid.y
                if abs(dy) >= missionControlThreshold {
                    triggeredMissionControl = true
                    delegate?.gestureDidTriggerMissionControl(up: dy > 0)   // up = MC, down = Exposé
                }
            }
            lastCentroid = c
            return                              // vertical or undetermined: take no window action
        }

        if !activated {
            if abs(dx) >= CGFloat(settings.activationThreshold) {
                activated = true
                stepAccumulator = 0
                stepAccumulatorY = 0
                lastCentroid = c
                delegate?.gestureDidActivate()
            } else {
                lastCentroid = c
            }
            return
        }

        // Active: accumulate signed horizontal travel and emit discrete window steps with carry.
        stepAccumulator += (c.x - lastCentroid.x)

        // Vertical → Space-row steps, but only when row switching is effective. When it is not, we
        // never accumulate or emit vertical: the three-finger vertical swipe is left entirely to
        // the OS (Mission Control / App Exposé), so it can't be stolen mid-overlay.
        if rowSwitchingEnabled {
            stepAccumulatorY += (c.y - lastCentroid.y)
        }
        lastCentroid = c

        let step = CGFloat(max(settings.stepDistance, 0.005))
        while stepAccumulator >= step { stepAccumulator -= step; emitStep(forward: true) }
        while stepAccumulator <= -step { stepAccumulator += step; emitStep(forward: false) }

        if rowSwitchingEnabled {
            let rowStep = CGFloat(max(settings.rowStepDistance, 0.02))
            while stepAccumulatorY >= rowStep { stepAccumulatorY -= rowStep; emitRowStep(up: true) }
            while stepAccumulatorY <= -rowStep { stepAccumulatorY += rowStep; emitRowStep(up: false) }
        }
    }

    private func emitStep(forward: Bool) {
        var dir = forward ? 1 : -1
        if settings.reverseDirection { dir = -dir }
        delegate?.gestureDidStep(dir)
    }

    /// `up` = finger moved up (OMS y increases upward). Default: up = next Space-row.
    private func emitRowStep(up: Bool) {
        var dir = up ? 1 : -1
        if settings.reverseVerticalDirection { dir = -dir }
        delegate?.gestureDidStepRow(dir)
    }

    private func end() {
        let didCommit = (axis == .horizontal && activated)
        state = .idle
        axis = .undetermined
        activated = false
        if didCommit {
            delegate?.gestureDidCommit()
        } else {
            delegate?.gestureDidCancel()
        }
    }

    private func cancel() {
        state = .idle
        axis = .undetermined
        activated = false
        delegate?.gestureDidCancel()
    }

    // MARK: - Launcher (four-finger)

    private func beginLauncher(_ frame: TouchFrame) {
        state = .tracking
        axis = .undetermined
        activated = false
        startCentroid = frame.centroid
        lastCentroid = frame.centroid
        stepAccumulator = 0
        stepAccumulatorY = 0
        belowTargetFrames = 0
        triggeredMissionControl = false
        launcherContacts = frame.fingerCount   // 4 at begin; tracked so a drop re-baselines the origin
        edgeDX = 0; edgeDY = 0
        // Rebuild the positional navigator from current settings (a tunable change between opens applies
        // here). It is anchored at activation, not begin — the opening fling moves the centroid, so the
        // navigation center is the post-fling resting position.
        // Position-tracking padding box: inside the box the selection follows the finger's position in
        // steps (center locked); leaving the box (or hitting the edge band) accelerates. Per-axis step /
        // radius / edge-margin are set per-feed (the band axis uses a coarser step on the band list).
        launcherNav = PositionalNavigator(
            footprintFactor: CGFloat(settings.positionalFootprintFactor),
            fallbackScale: CGFloat(settings.positionalFallbackScale),
            x: AxisZone(mode: .positionTracking),
            y: AxisZone(mode: .positionTracking))
        launcherNav.edgeMargin = CGFloat(settings.positionalEdgeMargin)
        launcherNav.reArmBackoff = CGFloat(settings.positionalReArmBackoff)
    }

    private func trackLauncher(_ frame: TouchFrame) {
        let count = frame.fingerCount

        if count > 4 {
            cancelLauncher()              // a 5th finger landed: abort, don't fire
            return
        }

        if count >= 2 {
            // Latched launcher lives while ≥2 contacts remain. The mode is never re-evaluated, so a
            // transient three-finger count while relaxing four fingers to two does NOT hand off to
            // the switcher and does NOT cancel. On any contact-count change the centroid shifts as
            // fingers leave (or land), so re-baseline the step origin and clear carry — only finger
            // movement *after* the new baseline advances the selection.
            belowTargetFrames = 0
            if count != launcherContacts {
                launcherContacts = count
                startCentroid = frame.centroid
                lastCentroid = frame.centroid
                stepAccumulator = 0
                stepAccumulatorY = 0
                // Post-activation navigation is positional: re-anchor the joystick center/scale at the
                // new posture so the centroid shift from a leaving/landing finger emits no step (the
                // re-anchor also resets the per-axis arm/zone state, clearing any held auto-repeat).
                if activated { launcherNav.reanchor(center: frame.centroid, spread: frame.footprintSpread) }
            }
            updateLauncher(frame)
        } else {
            // Below two contacts ("lift"): a real lift reports 0 immediately; an edge flicker dips
            // to 1 for a frame or two. End on a true lift or a sustained drop so a brush near the
            // edge doesn't prematurely fire/dismiss. The controller then fires-or-dismisses.
            belowTargetFrames += 1
            if count == 0 || belowTargetFrames >= 2 {
                endLauncher()
            }
        }
    }

    private func updateLauncher(_ frame: TouchFrame) {
        let c = frame.centroid
        let dx = c.x - startCentroid.x

        if !activated {
            // Activate on deliberate horizontal travel (the opening fling is UNCHANGED — odometer, not
            // positional). Pre-activation vertical is reserved (idle four-finger vertical does nothing in
            // v1), so only |Δx| arms the launcher. On activation, anchor the positional navigator at the
            // post-fling resting centroid so navigation offset is measured from where the hand settled.
            if abs(dx) >= CGFloat(settings.launcherActivationThreshold) {
                activated = true
                lastCentroid = c
                launcherNav.reanchor(center: c, spread: frame.footprintSpread)
                delegate?.launcherDidActivate()
            } else {
                lastCentroid = c
            }
            return
        }

        // Active: navigation is ANCHORED-POSITIONAL (change `positional-navigation`). The offset of the
        // centroid from the anchored center (footprint-scaled) is classified per axis into one discrete
        // step on each out-and-back across the outer threshold, plus a held-zone sign while an offset is
        // held (the controller turns that into eased auto-repeat). The threshold tracks the *action*:
        // band switching (VERTICAL on the band list) uses the coarser context outer-threshold so it stays
        // deliberate; all item movement uses the finer item outer-threshold.
        lastCentroid = c
        let onBandList = delegate?.launcherFocusIsOnBandList() ?? false
        let itemStep = CGFloat(max(settings.launcherStepDistance, 0.02))
        let bandStep = CGFloat(max(settings.launcherContextStepDistance, 0.02))
        // The padding box radius (how far you can step before the margin accelerates). Floor it above the
        // step so the box always holds at least one step.
        let radius = CGFloat(max(settings.positionalPaddingRadius, max(itemStep, bandStep) + 0.05))
        launcherNav.x.step = itemStep; launcherNav.x.radius = radius
        launcherNav.y.step = onBandList ? bandStep : itemStep; launcherNav.y.radius = radius

        let out = launcherNav.feed(centroid: c)
        // Position-tracking can move several steps in one frame (a fast sweep) — emit the whole delta.
        if out.stepX != 0 { for _ in 0..<abs(out.stepX) { emitItemStep(forward: out.stepX > 0) } }
        if out.stepY != 0 { for _ in 0..<abs(out.stepY) { emitContextStep(up: out.stepY > 0) } }
        updateHeldZones(dx: out.heldX, dy: out.heldY)
    }

    /// Emit the per-axis HELD-IN-ZONE sign (offset held beyond the outer threshold) when it changes, so
    /// the controller drives eased auto-repeat off it. Repurposes `launcherEdgeChanged` from physical-edge
    /// detection to positional held-zone (change `positional-navigation`, D3). Raw signs — the coordinator
    /// applies the reverse-direction settings, exactly as it did for the old edge state.
    private func updateHeldZones(dx: Int, dy: Int) {
        guard dx != edgeDX || dy != edgeDY else { return }
        edgeDX = dx; edgeDY = dy
        delegate?.launcherEdgeChanged(dx: dx, dy: dy)
    }

    private func clearEdges() {
        guard edgeDX != 0 || edgeDY != 0 else { return }
        edgeDX = 0; edgeDY = 0
        delegate?.launcherEdgeChanged(dx: 0, dy: 0)
    }

    private func emitItemStep(forward: Bool) {
        var dir = forward ? 1 : -1
        if settings.reverseDirection { dir = -dir }
        delegate?.launcherDidStepItem(dir)
    }

    private func emitContextStep(up: Bool) {
        var dir = up ? 1 : -1
        if settings.reverseVerticalDirection { dir = -dir }
        delegate?.launcherDidStepContext(dir)
    }

    private func endLauncher() {
        let didActivate = activated
        clearEdges()
        state = .idle
        axis = .undetermined
        activated = false
        // Only signal a lift when the overlay was actually shown; a sub-threshold four-finger swipe
        // that never activated has nothing to dismiss.
        if didActivate { delegate?.launcherDidEnd() }
    }

    private func cancelLauncher() {
        let wasActivated = activated
        clearEdges()
        state = .idle
        axis = .undetermined
        activated = false
        if wasActivated { delegate?.launcherDidCancel() }
    }

    // MARK: - Files drill (sustained modal sub-state; bypasses the latch while the navigator is open)

    /// Re-seed a fresh drill session. Called when the controller ENTERS the sub-state (the `didSet`
    /// false→true edge); the next contact re-baselines the origin. A truly one-shot resolution means
    /// `drillResolved` survives a lift WITHIN a session and only clears here, on the next entry.
    private func resetDrill() {
        drillStarted = false
        drillResolved = false
        pendingOpenWith = false
        drillContacts = 0
        belowTargetFrames = 0
        drillAccumX = 0
        drillAccumY = 0
        clearEdges()   // no held auto-repeat carried into a fresh drill session
    }

    /// Re-arm the SAME drill session for a fresh resolution **without** toggling `filesDrillActive`. After
    /// the +1-finger lift resolved the drill (`filesOpenWith`, one-shot — `drillResolved` latched), the
    /// Open-With picker opens and needs fresh gesture input to scrub it: this clears the one-shot resolution
    /// latch and re-seeds the drill scalars (exactly as a fresh entry would) so the next contact re-baselines
    /// and navigation resumes. It is NOT a re-entry — `filesDrillActive` stays true throughout — so the
    /// controller drives it explicitly right after entering the picker (mirroring how a re-entry would seed,
    /// but in place). The lift that opens the picker has already raised the fingers, so seeding from scratch
    /// here is correct: the picker is scrubbed by a brand-new gesture.
    func rearmDrill() {
        resetDrill()
    }

    /// Sustained drill tracking (see `filesDrillActive`). Unlike the one-shot canvas tracker this lives
    /// for the whole session while ≥2 contacts remain, emitting many depth/highlight steps. The origin is
    /// re-baselined (and carry cleared) on EVERY contact-count change so a leaving/landing finger emits no
    /// phantom step. Navigation (depth/highlight) happens at the relaxed posture (≤3 contacts); a FULL
    /// four-finger contact is the resolution-arming posture — a deliberate horizontal swipe-away there is a
    /// discard, a plain lift is an open (Open-With if a relative +1 finger was added). The resolving lift
    /// (count below two, with the standard below-target debounce) is a ONE-SHOT resolution; a stray re-lift
    /// after that emits nothing.
    private func trackFilesDrill(_ frame: TouchFrame) {
        let count = frame.fingerCount

        if count >= 2 {
            belowTargetFrames = 0
            if !drillStarted {
                drillStarted = true
                drillContacts = count
                drillStart = frame.centroid       // baseline for the 4-finger discard swipe
                drillLast = frame.centroid
                configureFilesNav()
                filesNav.reanchor(center: frame.centroid, spread: frame.footprintSpread)
                return
            }
            // A contact-count change shifts the centroid as fingers leave or land. Re-anchor the positional
            // center so the jump emits no step (and stop any held auto-repeat across the re-baseline); a
            // count rising ABOVE the relaxed baseline is the relative +1 Open-With morph (latched for the
            // lift). The baseline then follows the count. While resolved, the whole session is inert.
            if count != drillContacts {
                if count > drillContacts && !drillResolved { pendingOpenWith = true }
                drillContacts = count
                drillStart = frame.centroid
                drillLast = frame.centroid
                filesNav.reanchor(center: frame.centroid, spread: frame.footprintSpread)
                clearEdges()
                return
            }
            guard !drillResolved else { return }
            updateFilesDrill(frame)
        } else {
            // Below two contacts ("lift"): a real lift reports 0 immediately; an edge flicker dips to 1 for
            // a frame or two. Resolve on a true lift or a sustained drop (the same debounce as the launcher).
            belowTargetFrames += 1
            if count == 0 || belowTargetFrames >= 2 {
                resolveFilesDrillLift()
            }
        }
    }

    private func updateFilesDrill(_ frame: TouchFrame) {
        let c = frame.centroid

        // A full four-finger contact is the resolution-arming posture (the +1 morph past the navigation
        // postures). It does NOT navigate — instead a fresh deliberate horizontal swipe-away past the
        // activation threshold is a one-shot DISCARD (mirroring the canvas-resolution swipe). A plain lift
        // from here resolves Open-With (the +1 latch). Measuring from the re-baselined `drillStart` (set
        // when the 4th finger landed) means a small depth-sized nudge won't trip it; a deliberate sweep will.
        if drillContacts >= 4 {
            let dx = c.x - drillStart.x
            let dy = c.y - drillStart.y
            let threshold = CGFloat(settings.launcherActivationThreshold)
            let ratio = CGFloat(settings.axisLockRatio)
            if abs(dx) >= threshold && abs(dx) >= ratio * abs(dy) {
                drillResolved = true
                delegate?.filesDiscard()
            }
            drillLast = c
            return
        }

        // Relaxed navigation posture (≥2, ≤3 contacts): ANCHORED-POSITIONAL (change `positional-navigation`),
        // matching the launcher. HIGHLIGHT (vertical) position-tracks the finger inside the padding box and
        // accelerates at the margin (box edge / trackpad edge band), with pull-back-recenter. DEPTH
        // (horizontal) stays a DELIBERATE out-and-back — one folder descend/ascend per swipe, never
        // auto-drilling (it's a stack push/pop, not a cursor).
        drillLast = c
        let inner = CGFloat(max(settings.positionalInnerDeadzone, 0.01))
        let depthOuter = CGFloat(max(settings.launcherStepDistance, inner + 0.02))
        filesNav.x.inner = inner; filesNav.x.outer = depthOuter          // depth: out-and-back thresholds
        let highlightStep = CGFloat(max(settings.launcherStepDistance, 0.02))
        let radius = CGFloat(max(settings.positionalPaddingRadius, highlightStep + 0.05))
        filesNav.y.step = highlightStep; filesNav.y.radius = radius      // highlight: position-tracking box

        let out = filesNav.feed(centroid: c)
        // Depth: one step per out-and-back (stepX is ±1). Highlight: position-tracking can move several
        // rows in one frame — emit the whole delta.
        if out.stepX != 0 { emitDrillDepth(forward: out.stepX > 0) }
        if out.stepY != 0 { for _ in 0..<abs(out.stepY) { emitDrillHighlight(up: out.stepY > 0) } }
        // Vertical highlight auto-repeats while held; horizontal depth never auto-repeats (held dx = 0).
        updateHeldZones(dx: 0, dy: out.heldY)
    }

    /// Rebuild the Files-drill positional navigator from current settings (called when a fresh drill
    /// session seeds), so a tunable change applies on the next drill. Anchored separately by the caller.
    ///
    /// Matches the launcher's model on the HIGHLIGHT axis (vertical = position-tracking + margin accel +
    /// pull-back-recenter), while keeping DEPTH (horizontal = descend/ascend) a DELIBERATE out-and-back —
    /// depth is a folder-stack push/pop, not a cursor, so it must step one level at a time and never
    /// auto-drill (CLAUDE.md landmine). Per-axis params are set per-feed.
    private func configureFilesNav() {
        filesNav = PositionalNavigator(
            footprintFactor: CGFloat(settings.positionalFootprintFactor),
            fallbackScale: CGFloat(settings.positionalFallbackScale),
            x: AxisZone(mode: .outAndBack),       // depth: deliberate, one folder per swipe
            y: AxisZone(mode: .positionTracking)) // highlight: tracks the finger like the launcher
        filesNav.edgeMargin = CGFloat(settings.positionalEdgeMargin)
        filesNav.reArmBackoff = CGFloat(settings.positionalReArmBackoff)
    }

    /// The resolving lift: a one-shot Open-With (if a relative +1 finger was added) or plain Open. A lift
    /// after the session already resolved (e.g. a stray re-lift, or a four-finger discard) emits nothing.
    private func resolveFilesDrillLift() {
        clearEdges()   // the lift stops any held highlight auto-repeat
        guard !drillResolved else {
            drillStarted = false
            return
        }
        // Only resolve a session that actually started (a sub-threshold flicker before any contact does
        // nothing); seeding requires a real ≥2-finger contact.
        if drillStarted {
            drillResolved = true
            if pendingOpenWith {
                delegate?.filesOpenWith()
            } else {
                delegate?.filesOpen()
            }
        }
        drillStarted = false
    }

    private func emitDrillDepth(forward: Bool) {
        var dir = forward ? 1 : -1
        if settings.reverseDirection { dir = -dir }
        delegate?.filesDepth(dir)
    }

    private func emitDrillHighlight(up: Bool) {
        var dir = up ? 1 : -1
        if settings.reverseVerticalDirection { dir = -dir }
        delegate?.filesHighlight(dir)
    }

    // MARK: - Player (sustained modal sub-state; bypasses the latch while the player is open)

    /// Seed a fresh player session. Called when the controller ENTERS the sub-state (the `didSet` false→
    /// true edge); the next contact baselines the origin. Unlike the Files drill the player is PERSISTENT
    /// — a lift ends one scrub but stays in the player — so there is no session-wide one-shot "resolved".
    private func resetPlayer() {
        playerStarted = false
        playerMenuOpen = false
        playerContacts = 0
        playerMoved = false
        belowTargetFrames = 0
        clearPlayerHeldZones()
    }

    /// Sustained player tracking (see `playerActive`). Navigation (seek/volume) happens at the relaxed
    /// posture; a relative +1 finger raises the action menu; a four-finger gesture dismisses; a lift with
    /// no movement is a play/pause tap (or, while the menu is open, selects the highlighted row). The origin
    /// is re-anchored on every contact-count change so a leaving/landing finger emits no phantom step.
    private func trackPlayer(_ frame: TouchFrame) {
        let count = frame.fingerCount

        if count >= 2 {
            belowTargetFrames = 0
            if !playerStarted {
                playerStarted = true
                playerContacts = count
                playerMoved = false
                playerSeedCentroid = frame.centroid
                configurePlayerNav()
                playerNav.reanchor(center: frame.centroid, spread: frame.footprintSpread)
                return
            }
            if count != playerContacts {
                // A rising count is an intent (menu / dismiss); a falling count is just a relax. Detect the
                // intent BEFORE re-baselining (mirrors the Files +1 Open-With latch), then re-anchor the
                // positional center so the centroid jump from the changed contacts emits no phantom step.
                if count > playerContacts {
                    if count >= 4 || count >= playerContacts + 2 {
                        delegate?.playerDismiss()
                    } else {
                        delegate?.playerActionMenu()
                    }
                }
                playerContacts = count
                playerSeedCentroid = frame.centroid
                playerNav.reanchor(center: frame.centroid, spread: frame.footprintSpread)
                clearPlayerHeldZones()
                return
            }
            updatePlayer(frame)
        } else {
            // Below two contacts ("lift"): same below-target debounce as the launcher/files. A lift ends the
            // scrub but stays in the player; if nothing moved it's a tap (toggle), or selects an open menu.
            belowTargetFrames += 1
            if count == 0 || belowTargetFrames >= 2 {
                resolvePlayerLift()
            }
        }
    }

    private func updatePlayer(_ frame: TouchFrame) {
        let c = frame.centroid
        // Tap-vs-scrub: any travel past the axis-detect threshold marks this contact a scrub (so the lift
        // is not a play/pause tap). A true tap barely moves.
        if abs(c.x - playerSeedCentroid.x) >= axisDetectThreshold ||
           abs(c.y - playerSeedCentroid.y) >= axisDetectThreshold {
            playerMoved = true
        }

        let inner = CGFloat(max(settings.positionalInnerDeadzone, 0.01))
        let outer = CGFloat(max(settings.launcherStepDistance, inner + 0.02))
        playerNav.x.inner = inner; playerNav.x.outer = outer
        playerNav.y.inner = inner; playerNav.y.outer = outer

        let out = playerNav.feed(centroid: c)
        if out.stepX != 0 { emitPlayerSeek(forward: out.stepX > 0) }
        if out.stepY != 0 { emitPlayerVolume(up: out.stepY > 0) }
        // BOTH axes auto-repeat (seek + volume), unlike the depth/pin surfaces.
        updatePlayerHeldZones(dx: out.heldX, dy: out.heldY)
    }

    /// A resolving lift in the player. While the action menu is open, it SELECTS the highlighted row;
    /// otherwise a no-movement contact is a play/pause TAP (a scrub-end is a no-op — the player persists).
    /// Resets `playerStarted` so the next contact seeds a fresh scrub session.
    private func resolvePlayerLift() {
        clearPlayerHeldZones()
        if playerStarted {
            if playerMenuOpen {
                delegate?.playerSelectMenuItem()
            } else if !playerMoved {
                delegate?.playerTogglePlayPause()
            }
        }
        playerStarted = false
        playerMoved = false
    }

    /// Rebuild the player positional navigator from current settings (called when a fresh session seeds),
    /// so a tunable change applies on the next session. Anchored separately by the caller.
    private func configurePlayerNav() {
        playerNav = PositionalNavigator(
            footprintFactor: CGFloat(settings.positionalFootprintFactor),
            fallbackScale: CGFloat(settings.positionalFallbackScale),
            inner: CGFloat(settings.positionalInnerDeadzone),
            outer: CGFloat(settings.launcherStepDistance))
        playerNav.reArmBackoff = CGFloat(settings.positionalReArmBackoff)
    }

    private func updatePlayerHeldZones(dx: Int, dy: Int) {
        guard dx != playerEdgeDX || dy != playerEdgeDY else { return }
        playerEdgeDX = dx; playerEdgeDY = dy
        delegate?.playerHeldZoneChanged(dx: dx, dy: dy)
    }

    private func clearPlayerHeldZones() {
        guard playerEdgeDX != 0 || playerEdgeDY != 0 else { return }
        playerEdgeDX = 0; playerEdgeDY = 0
        delegate?.playerHeldZoneChanged(dx: 0, dy: 0)
    }

    private func emitPlayerSeek(forward: Bool) {
        var dir = forward ? 1 : -1
        if settings.reverseDirection { dir = -dir }
        delegate?.playerSeek(dir)
    }

    private func emitPlayerVolume(up: Bool) {
        var dir = up ? 1 : -1
        if settings.reverseVerticalDirection { dir = -dir }
        delegate?.playerVolume(dir)
    }
}
