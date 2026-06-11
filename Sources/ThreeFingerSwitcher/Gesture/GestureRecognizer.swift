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
    /// Edge-hold state for scroll acceleration, per axis (−1 / 0 / +1): `edgeDX +1` = right edge,
    /// `edgeDY +1` = top edge. Emitted to the delegate when either changes.
    private var edgeDX = 0
    private var edgeDY = 0
    /// Normalized distance from a trackpad edge within which a held contact triggers auto-repeat, with
    /// hysteresis (enter < exit) so micro-jitter at the boundary doesn't flap the hold on/off. The
    /// enter zone is generous because a multi-finger centroid can't physically reach the very edge.
    private let edgeEnterZone: CGFloat = 0.16
    private let edgeExitZone: CGFloat = 0.24
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

    /// One-shot canvas-resolution tracking (see `launcherCanvasResolutionActive`). A fresh four-finger
    /// swipe past the activation threshold reports a single `launcherCanvasResolve`: vertical-dominant →
    /// `dy` (`+1` up, `-1` down; down applies, up is ignored upstream), else horizontal → `dx` (discard).
    /// Relaxing to ≥2 fingers after the four-finger start is allowed, matching the launcher's latch feel.
    /// Runs INSTEAD of the normal state machine while the canvas is open, so it never opens the launcher
    /// or switcher; it self-resets on lift.
    private func trackCanvasResolution(_ frame: TouchFrame) {
        let count = frame.fingerCount
        if count == 0 {                       // lift → ready for the next resolution gesture
            canvasResStarted = false
            canvasResResolved = false
            return
        }
        if !canvasResStarted {
            guard count >= 4 else { return }  // require a fresh four-finger contact to begin
            canvasResStarted = true
            canvasResResolved = false
            canvasResStart = frame.centroid
            return
        }
        guard !canvasResResolved, count >= 2 else { return }
        let dx = frame.centroid.x - canvasResStart.x
        let dy = frame.centroid.y - canvasResStart.y
        let threshold = CGFloat(settings.launcherActivationThreshold)
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
            // Activate on deliberate horizontal travel. Pre-activation vertical is reserved (idle
            // four-finger vertical does nothing in v1), so only |Δx| arms the launcher.
            if abs(dx) >= CGFloat(settings.launcherActivationThreshold) {
                activated = true
                stepAccumulator = 0
                stepAccumulatorY = 0
                lastCentroid = c
                delegate?.launcherDidActivate()
            } else {
                lastCentroid = c
            }
            return
        }

        // Active: the launcher owns both axes (the freed four-finger scroll is consumed by the scroll
        // tap). Horizontal moves the item cursor and crosses between the band list and the grid; vertical
        // switches bands (on the band list) or steps between grid rows (in the grid) — both with carry.
        // The threshold tracks the *action*, not the axis: switching bands (VERTICAL on the band list)
        // uses the coarser context-step so it can be made deliberate independently; all item movement —
        // horizontal in the grid and vertical between grid rows — uses the finer item-step. So raising
        // the context-step slows band switching without touching item movement.
        stepAccumulator += (c.x - lastCentroid.x)
        stepAccumulatorY += (c.y - lastCentroid.y)
        lastCentroid = c

        let itemStep = CGFloat(max(settings.launcherStepDistance, 0.005))
        let onBandList = delegate?.launcherFocusIsOnBandList() ?? false
        let horizStep = itemStep
        let vertStep = onBandList ? CGFloat(max(settings.launcherContextStepDistance, 0.02)) : itemStep
        while stepAccumulator >= horizStep { stepAccumulator -= horizStep; emitItemStep(forward: true) }
        while stepAccumulator <= -horizStep { stepAccumulator += horizStep; emitItemStep(forward: false) }

        while stepAccumulatorY >= vertStep { stepAccumulatorY -= vertStep; emitContextStep(up: true) }
        while stepAccumulatorY <= -vertStep { stepAccumulatorY += vertStep; emitContextStep(up: false) }

        updateEdges(c)
    }

    /// Track whether the controlling contact is held at a trackpad edge on each axis (with hysteresis),
    /// emitting `launcherEdgeChanged` only when the per-axis state changes. The controller decides what
    /// to auto-repeat (and clamps when there's nowhere to go).
    private func updateEdges(_ c: CGPoint) {
        let dx = edgeAxis(c.x, current: edgeDX)
        let dy = edgeAxis(c.y, current: edgeDY)
        guard dx != edgeDX || dy != edgeDY else { return }
        edgeDX = dx; edgeDY = dy
        delegate?.launcherEdgeChanged(dx: dx, dy: dy)
    }

    /// Per-axis edge direction with hysteresis: enter an edge at `edgeEnterZone`, leave it only past
    /// `edgeExitZone`, so jitter at the boundary doesn't flap. `+1` = high edge, `-1` = low edge.
    private func edgeAxis(_ v: CGFloat, current: Int) -> Int {
        if current > 0 { return v >= 1 - edgeExitZone ? 1 : (v <= edgeEnterZone ? -1 : 0) }
        if current < 0 { return v <= edgeExitZone ? -1 : (v >= 1 - edgeEnterZone ? 1 : 0) }
        if v >= 1 - edgeEnterZone { return 1 }
        if v <= edgeEnterZone { return -1 }
        return 0
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
}
