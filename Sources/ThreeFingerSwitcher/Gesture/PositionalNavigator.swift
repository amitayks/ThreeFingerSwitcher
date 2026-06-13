import CoreGraphics

/// The anchored-positional ("virtual joystick") navigation core (change `positional-navigation`).
/// Pure — no AppKit, no `TouchFrame`, no timers — so the whole model is exhaustively unit-testable, and
/// the recognizer holds one instance per navigable surface (the launcher grid, the Files drill).
///
/// Two zone behaviors live here, picked per axis:
///
/// - **Position-tracking** (the launcher): the area around the locked center is a **padding box**; the
///   selection index *follows the finger's position* in discrete steps (move out → step out, move back →
///   step back), with the center LOCKED. Leaving the box — `|offset| ≥ radius`, or the centroid entering
///   the fixed **edge-margin band** at the trackpad border — enters the **margin**, where navigation
///   becomes eased auto-repeat (the controller drives it off the held sign). A small move back from the
///   margin re-centers onto the finger and stops (see `reArmBackoff`).
/// - **Out-and-back** (the Files drill): the original hysteresis behavior — cross `outer` → one step +
///   held; return inside `inner` (deadzone) → re-arm. Kept so the Files drill's deliberate depth and
///   highlight stepping are unchanged.

struct AxisZone {
    /// Which behavior this axis uses.
    enum Mode { case outAndBack, positionTracking }
    var mode: Mode

    // Out-and-back params (used in `.outAndBack`).
    /// Deadzone half-width: returning inside this re-arms the axis. `< outer`.
    var inner: CGFloat
    /// Activation half-width: crossing this emits one step. `> inner`.
    var outer: CGFloat

    // Position-tracking params (used in `.positionTracking`).
    /// Offset per position-step inside the padding box.
    var step: CGFloat
    /// Box half-width: `|offset| ≥ radius` leaves the box → the margin (acceleration). `> step`.
    var radius: CGFloat

    /// `0` = at/near center (armed / inside the box); `±1` = held beyond the threshold (out-and-back) or
    /// accelerating in the margin (position-tracking) on that side.
    private(set) var heldSign: Int = 0
    /// Net position-steps emitted since the center lock (position-tracking reference; `0` = center).
    private(set) var index: Int = 0

    init(mode: Mode = .outAndBack, inner: CGFloat = 0, outer: CGFloat = 0,
         step: CGFloat = 0, radius: CGFloat = 0) {
        self.mode = mode
        self.inner = inner
        self.outer = outer
        self.step = step
        self.radius = radius
    }

    /// The furthest position-index the padding box holds on each side (the box edge, in steps).
    var maxIndex: Int { step > 0 ? Int((radius / step).rounded(.towardZero)) : 0 }

    /// Feed the axis offset (and, for position-tracking, whether the navigator classified this axis as
    /// being in the margin). Returns the net step **delta** to emit this frame (can be `>1` if the finger
    /// moved several steps at once). The sustained held state is read via `heldSign`.
    mutating func feed(_ offset: CGFloat, inMargin: Bool) -> Int {
        switch mode {
        case .outAndBack: return feedOutAndBack(offset)
        case .positionTracking: return feedPositionTracking(offset, inMargin: inMargin)
        }
    }

    /// Convenience for out-and-back callers/tests (the margin flag only applies to position-tracking).
    @discardableResult
    mutating func feed(_ offset: CGFloat) -> Int { feed(offset, inMargin: false) }

    private mutating func feedOutAndBack(_ offset: CGFloat) -> Int {
        if heldSign == 0 {
            if offset >= outer { heldSign = 1; return 1 }
            if offset <= -outer { heldSign = -1; return -1 }
            return 0
        }
        if abs(offset) <= inner { heldSign = 0; return 0 }
        if heldSign > 0 && offset <= -outer { heldSign = -1; return -1 }
        if heldSign < 0 && offset >= outer { heldSign = 1; return 1 }
        return 0
    }

    private mutating func feedPositionTracking(_ offset: CGFloat, inMargin: Bool) -> Int {
        let maxIdx = maxIndex
        if inMargin {
            // Accelerate: snap the index to the box edge on the held side (position-tracking already
            // carried us there) and report the held sign; the controller auto-repeats beyond it.
            let sign = offset > 0 ? 1 : (offset < 0 ? -1 : (heldSign == 0 ? 1 : heldSign))
            heldSign = sign
            let boundary = sign >= 0 ? maxIdx : -maxIdx
            let delta = boundary - index
            index = boundary
            return delta
        }
        heldSign = 0
        let raw = step > 0 ? Int((offset / step).rounded(.toNearestOrAwayFromZero)) : 0
        let target = Swift.max(-maxIdx, Swift.min(maxIdx, raw))
        let delta = target - index
        index = target
        return delta
    }

    /// Reset to the locked-center reference (re-anchor / contact-count change → no spurious step).
    mutating func reset() { heldSign = 0; index = 0 }
}

/// The center + footprint-derived scale that turns a raw centroid into a normalized offset.
struct PositionalAnchor: Equatable {
    /// The anchored center (where the hand settled / re-baselined).
    let center: CGPoint
    /// Full-deflection distance: `footprintFactor · spread`, or the fixed fallback. Always `> 0`.
    let scale: CGFloat

    init(center: CGPoint, spread: CGFloat?, footprintFactor: CGFloat, fallbackScale: CGFloat) {
        self.center = center
        let floored = max(fallbackScale, 0.0001)
        if let spread, spread > 0.0001 {
            self.scale = max(footprintFactor * spread, 0.0001)
        } else {
            self.scale = floored
        }
    }

    /// Re-center on a new point while keeping the same deflection scale — used when a back-move snaps the
    /// center onto the finger mid-gesture (the footprint hasn't meaningfully changed, so the scale is kept).
    init(center: CGPoint, scale: CGFloat) {
        self.center = center
        self.scale = max(scale, 0.0001)
    }

    /// The normalized per-axis offset of `centroid` from the anchor (`±1` ≈ full deflection).
    func offset(for centroid: CGPoint) -> CGPoint {
        CGPoint(x: (centroid.x - center.x) / scale, y: (centroid.y - center.y) / scale)
    }
}

/// Bundles the anchor + two `AxisZone`s for a navigable surface. The recognizer (re)anchors it on entry
/// and on every contact-count change, then feeds centroids; each feed yields the per-axis step delta and
/// the held signs the controller uses to drive eased auto-repeat.
struct PositionalNavigator {
    /// How many footprint-widths of travel reach full deflection.
    var footprintFactor: CGFloat
    /// Fixed full-deflection distance when the footprint is unavailable (test frames, degenerate spread).
    var fallbackScale: CGFloat
    /// Horizontal axis zone.
    var x: AxisZone
    /// Vertical axis zone.
    var y: AxisZone

    /// Fixed band (absolute normalized units) along the trackpad's inner border. While a position-tracking
    /// axis's centroid is within this of the border (pushing outward), it is treated as the **margin**
    /// (accelerate) even before the box radius is reached — the always-present "min margin" the padding box
    /// squeezes against near the edges. `0` disables the edge band (box radius alone gates the margin).
    var edgeMargin: CGFloat = 0

    /// How far the offset may retreat from its furthest held point (offset units) before the center snaps
    /// onto the finger and the auto-repeat stops (the "small move back re-centers" refinement). `0` disables.
    var reArmBackoff: CGFloat = 0

    private var anchor: PositionalAnchor?
    private var peakX: CGFloat = 0
    private var peakY: CGFloat = 0

    init(footprintFactor: CGFloat, fallbackScale: CGFloat, x: AxisZone, y: AxisZone) {
        self.footprintFactor = footprintFactor
        self.fallbackScale = fallbackScale
        self.x = x
        self.y = y
    }

    /// Convenience: build both axes as **out-and-back** (the Files drill / media player default). Keeps the
    /// original `inner:outer:` call shape working for surfaces that haven't moved to position-tracking.
    init(footprintFactor: CGFloat, fallbackScale: CGFloat, inner: CGFloat, outer: CGFloat) {
        self.init(footprintFactor: footprintFactor, fallbackScale: fallbackScale,
                  x: AxisZone(mode: .outAndBack, inner: inner, outer: outer),
                  y: AxisZone(mode: .outAndBack, inner: inner, outer: outer))
    }

    /// Whether the navigator has an anchor yet.
    var isAnchored: Bool { anchor != nil }

    /// (Re)anchor the center + scale and reset both axes, so a re-baseline (entry or contact-count change)
    /// emits no step and the next offset is measured from here.
    mutating func reanchor(center: CGPoint, spread: CGFloat?) {
        anchor = PositionalAnchor(center: center, spread: spread,
                                  footprintFactor: footprintFactor, fallbackScale: fallbackScale)
        x.reset()
        y.reset()
        peakX = 0
        peakY = 0
    }

    /// Per feed: the per-axis step delta (`0`/`±n`) plus the held sign (`0`/`±1`) for auto-repeat.
    struct Output: Equatable {
        var stepX: Int
        var stepY: Int
        var heldX: Int
        var heldY: Int
    }

    /// Feed a centroid. A no-op until anchored.
    ///
    /// Order: (1) retreat-recenter — while accelerating in the margin, a back-move retreating from the peak
    /// by `reArmBackoff` snaps the center to the finger and stops; (2) classify each position-tracking axis
    /// as in-the-box (position step) or in-the-margin (`|offset| ≥ radius`, or near the edge band) and feed.
    mutating func feed(centroid: CGPoint) -> Output {
        guard let anchor else { return Output(stepX: 0, stepY: 0, heldX: 0, heldY: 0) }
        let off = anchor.offset(for: centroid)

        if reArmBackoff > 0,
           (x.heldSign != 0 && peakX - abs(off.x) >= reArmBackoff) ||
           (y.heldSign != 0 && peakY - abs(off.y) >= reArmBackoff) {
            self.anchor = PositionalAnchor(center: centroid, scale: anchor.scale)
            x.reset(); y.reset()
            peakX = 0; peakY = 0
            return Output(stepX: 0, stepY: 0, heldX: 0, heldY: 0)
        }

        let marginX = inMargin(zone: x, offset: off.x, centroidPos: centroid.x)
        let marginY = inMargin(zone: y, offset: off.y, centroidPos: centroid.y)
        let dx = x.feed(off.x, inMargin: marginX)
        let dy = y.feed(off.y, inMargin: marginY)
        peakX = x.heldSign != 0 ? max(peakX, abs(off.x)) : 0
        peakY = y.heldSign != 0 ? max(peakY, abs(off.y)) : 0
        return Output(stepX: dx, stepY: dy, heldX: x.heldSign, heldY: y.heldSign)
    }

    /// True when a position-tracking axis has left its box (`|offset| ≥ radius`) or the centroid is pushing
    /// into the fixed edge-margin band. Out-and-back axes never use the margin (always false).
    private func inMargin(zone: AxisZone, offset: CGFloat, centroidPos: CGFloat) -> Bool {
        guard zone.mode == .positionTracking else { return false }
        if zone.radius > 0 && abs(offset) >= zone.radius { return true }
        if edgeMargin > 0 {
            if offset > 0 && centroidPos >= 1 - edgeMargin { return true }
            if offset < 0 && centroidPos <= edgeMargin { return true }
        }
        return false
    }
}

/// The eased auto-repeat cadence (change `positional-navigation`, D4). The interval is a smooth function of
/// dwell duration, so holding in the margin accelerates along a curve rather than jumping slow→fast.
///
/// At `dwellElapsed == 0` it returns `initialDelay` (the gap before the *second* margin step — the first
/// fired immediately on entering the margin); it then eases to `floor` as the dwell reaches `rampTime`.
enum RepeatCadence {
    static func interval(dwellElapsed: Double,
                         initialDelay: Double,
                         floor: Double,
                         rampTime: Double) -> Double {
        guard rampTime > 0 else { return floor }
        let x = min(1, max(0, dwellElapsed) / rampTime)
        let eased = 1 - (1 - x) * (1 - x)          // ease-out quad: 0 → 1
        return floor + (initialDelay - floor) * (1 - eased)
    }
}
