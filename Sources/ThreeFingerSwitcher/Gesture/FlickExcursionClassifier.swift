import Foundation
import CoreGraphics

/// The pure fast-vs-soft flick classifier (D4 of the canvas grammar, extracted by
/// `notch-conversation-gestures` so the launcher canvas and the expanded notch conversation share ONE
/// implementation — the constants and feel can never drift between surfaces).
///
/// One instance tracks ONE excursion: `begin` seeds the origin, `track` accumulates the per-axis PEAK of
/// the smoothed centroid speed plus the timing of the last genuinely-fast frame (the lift frame is empty
/// with `.zero` velocity, so the flick speed must come from the last in-contact frame), and
/// `classifyOnLift` renders the D4 verdict: a FLICK requires (a) the dominant axis's travel to have
/// crossed the floor, (b) its peak velocity to have crossed the threshold, AND (c) the lift to have
/// arrived within the lift window of the last fast frame. A slow reading-scrub (sub-threshold peak) or a
/// decelerated hold-then-lift is a SCROLL and classifies as nil — the caller emits nothing and native
/// scrolling is untouched.
///
/// Pure value type — no clocks, no settings; every threshold is an input, so it is deterministic under
/// `swift test`. The caller owns routing (which frames feed it) and one-shot emission.
struct FlickExcursionClassifier {
    /// Whether an excursion is being tracked (`begin` ran; `reset` clears it).
    private(set) var started = false

    private var start = CGPoint.zero
    /// Running PEAK of `abs(centroidVelocity)` per axis across the in-contact frames.
    private var peakVelX: CGFloat = 0
    private var peakVelY: CGFloat = 0
    /// Timestamp of the most recent in-contact frame whose DOMINANT-axis speed crossed the threshold,
    /// and the most recent in-contact frame's timestamp (the lift window is measured between them).
    private var lastFastTime: CFTimeInterval = 0
    private var lastContactTime: CFTimeInterval = 0
    /// Signed dominant-axis travel captured from the last in-contact frame, so the (empty) lift frame
    /// can still classify direction and the travel floor.
    private var lastDX: CGFloat = 0
    private var lastDY: CGFloat = 0
    /// Whether any in-contact frame crossed the velocity threshold on its dominant axis.
    private var sawFastFrame = false

    /// Seed a fresh excursion at the first qualifying contact frame.
    mutating func begin(at centroid: CGPoint, time: CFTimeInterval) {
        reset()
        started = true
        start = centroid
        lastContactTime = time
    }

    /// Accumulate one in-contact frame: travel from the origin, per-axis velocity peaks, and the
    /// last-fast-frame timing (dominant axis chosen per-frame by `axisLockRatio`, exactly as the canvas
    /// path always did). No-op until `begin`.
    mutating func track(centroid: CGPoint, velocity: CGVector, time: CFTimeInterval,
                        velocityThreshold: CGFloat, axisLockRatio: CGFloat) {
        guard started else { return }
        let dx = centroid.x - start.x
        let dy = centroid.y - start.y
        let verticalDominant = abs(dy) >= axisLockRatio * abs(dx)
        let vx = abs(velocity.dx)
        let vy = abs(velocity.dy)
        peakVelX = max(peakVelX, vx)
        peakVelY = max(peakVelY, vy)
        lastContactTime = time
        lastDX = dx
        lastDY = dy
        let dominantSpeed = verticalDominant ? vy : vx
        if dominantSpeed >= velocityThreshold {
            sawFastFrame = true
            lastFastTime = time
        }
    }

    /// Classify the just-ended excursion (call on the lift frame, `fingerCount == 0`): an axis-locked
    /// flick — exactly one of `dx`/`dy` non-zero, `+1` right/up, `-1` left/down — or nil for a soft
    /// scrub, a decelerated lift, or travel under the floor. Does not mutate; the caller `reset()`s.
    func classifyOnLift(travelFloor: CGFloat, velocityThreshold: CGFloat,
                        liftWindow: CFTimeInterval, axisLockRatio: CGFloat) -> (dx: Int, dy: Int)? {
        guard started else { return nil }
        let verticalDominant = abs(lastDY) >= axisLockRatio * abs(lastDX)
        // (a) Travel floor: the dominant axis must have crossed it.
        let dominantTravel = verticalDominant ? abs(lastDY) : abs(lastDX)
        guard dominantTravel >= travelFloor else { return nil }
        // (b) Peak velocity: the dominant axis must have flicked fast at some point.
        let dominantPeak = verticalDominant ? peakVelY : peakVelX
        guard dominantPeak >= velocityThreshold else { return nil }   // slow scrub → SCROLL
        // (c) Prompt lift: the lift must follow the last fast frame within the window (a pause before
        // lifting means the fingers decelerated to a hold/scroll).
        guard sawFastFrame, lastContactTime - lastFastTime <= liftWindow else { return nil }
        if verticalDominant {
            return (dx: 0, dy: lastDY > 0 ? 1 : -1)   // dy>0 = up, dy<0 = down
        }
        return (dx: lastDX > 0 ? 1 : -1, dy: 0)
    }

    /// Clear all per-excursion state so peaks, timing, and travel never leak across gestures.
    mutating func reset() {
        started = false
        start = .zero
        peakVelX = 0
        peakVelY = 0
        lastFastTime = 0
        lastContactTime = 0
        lastDX = 0
        lastDY = 0
        sawFastFrame = false
    }
}
