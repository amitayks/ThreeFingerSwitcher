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
}

/// Three-finger horizontal scrub state machine.
///
///   idle ──(3 fingers)──▶ candidate ──┬─(vertical dominates)─▶ yielding ──(lift)─▶ idle
///                                      └─(horizontal dominates)▶ horizontal
///   horizontal ──(|Δx| ≥ activation)─▶ active (overlay shown), steps emitted
///   active ──(lift)─▶ commit ; horizontal-but-not-active ──(lift)─▶ cancel
///   any ──(4th finger)─▶ cancel
@MainActor
final class GestureRecognizer {
    weak var delegate: GestureRecognizerDelegate?

    private let settings: AppSettings

    /// Whether vertical Space-row stepping is active. Off by default; the coordinator sets it true
    /// only when the Space-row switching opt-in is *effective* — i.e. enabled AND the native
    /// three-finger vertical gesture has actually been relocated to four fingers (so the OS no
    /// longer steals the vertical swipe). When false, vertical motion is left entirely to the OS.
    var rowSwitchingEnabled = false

    private enum Axis { case undetermined, horizontal, vertical }
    private enum State { case idle, tracking }

    private var state: State = .idle
    private var axis: Axis = .undetermined
    private var activated = false
    /// One-shot guard so a fresh vertical swipe triggers Mission Control / App Exposé only once.
    private var triggeredMissionControl = false
    /// Consecutive frames seen below the required finger count (to debounce edge flicker vs. a
    /// real lift). A true lift reports 0 fingers immediately; an edge flicker dips to 1–2 briefly.
    private var belowTargetFrames = 0

    private var startCentroid = CGPoint.zero
    private var lastCentroid = CGPoint.zero
    private var stepAccumulator: CGFloat = 0    // horizontal → window steps
    private var stepAccumulatorY: CGFloat = 0   // vertical → Space-row steps (post-activation only)

    /// Small movement needed before we attempt to decide the axis (normalized).
    private let axisDetectThreshold: CGFloat = 0.012

    /// Deliberate vertical travel (normalized) before a fresh vertical swipe triggers Mission
    /// Control / App Exposé — larger than axis detection so it isn't twitchy.
    private let missionControlThreshold: CGFloat = 0.10

    init(settings: AppSettings) {
        self.settings = settings
    }

    func feed(_ frame: TouchFrame) {
        let target = settings.requireExactlyThree ? (frame.fingerCount == 3) : (frame.fingerCount >= 3)
        let tooMany = settings.requireExactlyThree ? (frame.fingerCount > 3) : false

        switch state {
        case .idle:
            if target { begin(frame) }
            // else: ignore (0/1/2 fingers, or vertical handled by OS anyway)

        case .tracking:
            if tooMany {
                cancel()                      // a 4th finger landed
            } else if target {
                belowTargetFrames = 0
                update(frame)                 // still scrubbing
            } else {
                // Below the required count: a real lift reports 0 fingers; an edge flicker dips
                // to 1–2 for a frame or two. Only end on a true lift or a sustained drop, so
                // swiping toward the trackpad edge doesn't prematurely commit/close.
                belowTargetFrames += 1
                if frame.fingerCount == 0 || belowTargetFrames >= 2 {
                    end()
                }
                // otherwise ignore this frame and wait for the 3rd finger to return
            }
        }
    }

    /// Abort any in-flight gesture (e.g. when the engine stops).
    func reset() {
        if state == .tracking { cancel() }
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
            return
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
}
