import CoreGraphics
import Foundation

/// A pure, MLX-free ghost-hand pose generator — the "self-playing clip" engine behind both the
/// First Touch wizard's attract loop and the Hub's gesture previews. Given a continuous `phase`
/// it returns one frame: a centroid plus a hand-like arc of fingertips, all normalized to 0..1
/// trackpad space and clamped to `[0.05, 0.95]` (so the hand never leaves the pad). Generalized
/// from `FirstTouchWizardModel.attractPose`: parameterized by finger **count** (2/3/4 fingertips)
/// and **axis** (a horizontal ping-pong, a vertical ping-pong, or a scripted sequence of keyframed
/// centroid targets the Hub band-page previews and hover-demos drive). Everything is `nonisolated`
/// and value-typed so it is trivially unit-testable and callable from any context.
enum GesturePose {

    /// The axis a ghost hand sweeps along.
    enum Axis: Equatable {
        /// Centroid ping-pongs horizontally across the pad (the original attract loop).
        case horizontal
        /// Centroid ping-pongs vertically across the pad.
        case vertical
        /// A choreographed path: the centroid travels through `keyframes` in order, interpolating
        /// between neighbours and looping back to the first. This is the multi-step
        /// open → traverse-to-band → in-surface-gesture journey the band pages and the hover-demo
        /// state need — a single `pose(phase:…)` call returns the interpolated frame along the path.
        case scripted([Keyframe])
    }

    /// One stop on a scripted path: a normalized centroid the hand should reach.
    struct Keyframe: Equatable {
        var centroid: CGPoint
        init(centroid: CGPoint) { self.centroid = centroid }
        init(x: CGFloat, y: CGFloat) { self.centroid = CGPoint(x: x, y: y) }
    }

    /// The lower / upper clamp every coordinate is held within, so the hand never touches the
    /// pad edge — identical to the original attract loop.
    nonisolated static let lowerBound: CGFloat = 0.05
    nonisolated static let upperBound: CGFloat = 0.95

    /// One full sweep ≈ 6.5 s at the wizard's 30 Hz tick — unhurried, self-evidently alive.
    /// (The same cadence the wizard used; kept here so every preview shares one pace.)
    nonisolated static let phaseStep = (2 * Double.pi) / (6.5 * 30)

    /// One ghost-hand pose for the given continuous `phase`. The centroid follows `axis`; the
    /// `fingers` fingertips fan out from it in a hand-like arc, each carrying a faint organic
    /// wobble so the hand reads as a hand, not a cursor. All coordinates are clamped to
    /// `[lowerBound, upperBound]`. The 3-finger `.horizontal` case reproduces the original
    /// `attractPose(phase:)` output exactly, so onboarding is visually unchanged.
    nonisolated static func pose(phase: Double,
                                 fingers: Int = 3,
                                 axis: Axis = .horizontal) -> (centroid: CGPoint, dots: [CGPoint]) {
        let centroid = centroid(phase: phase, axis: axis)
        let dots = fingertips(around: centroid, fingers: fingers, phase: phase)
        return (centroid, dots)
    }

    // MARK: - Centroid path

    /// The unclamped centroid for an axis at `phase`. Horizontal mirrors the original loop
    /// (`x = 0.5 + 0.40 sin`, `y = 0.42 + 0.05 sin(0.63·)`); vertical swaps the roles; scripted
    /// interpolates along its keyframes.
    nonisolated private static func centroid(phase: Double, axis: Axis) -> CGPoint {
        switch axis {
        case .horizontal:
            return CGPoint(x: 0.5 + 0.40 * sin(phase),
                           y: 0.42 + 0.05 * sin(phase * 0.63))
        case .vertical:
            // The mirror image of horizontal: the dominant sweep is on Y, a gentle drift on X.
            return CGPoint(x: 0.5 + 0.05 * sin(phase * 0.63),
                           y: 0.5 + 0.40 * sin(phase))
        case .scripted(let keyframes):
            return scriptedCentroid(phase: phase, keyframes: keyframes)
        }
    }

    /// Walk the scripted path: split one full cycle (`2π`) into equal legs between consecutive
    /// keyframes (and a final leg back to the first, so it loops), then linearly interpolate the
    /// centroid along the current leg. With one keyframe the hand simply rests there; with none it
    /// falls back to pad center.
    nonisolated private static func scriptedCentroid(phase: Double, keyframes: [Keyframe]) -> CGPoint {
        guard let first = keyframes.first else { return CGPoint(x: 0.5, y: 0.5) }
        guard keyframes.count > 1 else { return first.centroid }

        // Normalize phase into [0, 1) over one loop. `keyframes.count` legs: each keyframe to the
        // next, with the last wrapping back to the first.
        let cycle = 2 * Double.pi
        var t = phase.truncatingRemainder(dividingBy: cycle) / cycle
        if t < 0 { t += 1 }

        let legCount = keyframes.count          // includes the wrap-around leg
        let scaled = t * Double(legCount)
        let leg = min(legCount - 1, Int(scaled))
        let local = CGFloat(scaled - Double(leg))   // 0..1 within this leg

        let start = keyframes[leg].centroid
        let end = keyframes[(leg + 1) % keyframes.count].centroid
        return CGPoint(x: start.x + (end.x - start.x) * local,
                       y: start.y + (end.y - start.y) * local)
    }

    // MARK: - Fingertip arc

    /// The fingertip offsets (relative to the centroid) for a hand-like arc of `fingers` tips.
    /// 3 fingers reproduce the original attract arc exactly; 2 and 4 are symmetric arcs of the
    /// same character (outer tips lower, inner tips raised — the natural curl of a resting hand).
    nonisolated private static func arcOffsets(fingers: Int) -> [(CGFloat, CGFloat)] {
        switch max(2, min(4, fingers)) {
        case 2:
            return [(-0.10, 0.13), (0.10, 0.13)]
        case 4:
            return [(-0.21, 0.10), (-0.07, 0.17), (0.07, 0.17), (0.21, 0.10)]
        default:    // 3 — the original attract arc, byte-for-byte
            return [(-0.16, 0.10), (0, 0.17), (0.16, 0.10)]
        }
    }

    /// Place the fingertips around a centroid with the same organic wobble + clamp as the
    /// original attract loop, so the 3-finger horizontal case is identical to `attractPose`.
    nonisolated private static func fingertips(around centroid: CGPoint,
                                               fingers: Int,
                                               phase: Double) -> [CGPoint] {
        arcOffsets(fingers: fingers).enumerated().map { index, offset in
            CGPoint(x: clamp(centroid.x + offset.0 + 0.012 * sin(phase * 1.7 + Double(index))),
                    y: clamp(centroid.y + offset.1 + 0.012 * cos(phase * 1.3 + Double(index))))
        }
    }

    nonisolated private static func clamp(_ value: CGFloat) -> CGFloat {
        min(upperBound, max(lowerBound, value))
    }

    // MARK: - §11.1 Directed-stroke model (pose driver v2)

    /// One decisive directed swipe in a demonstration. The hand presses down with `fingers` tips at
    /// `from`, strokes (eased) to `to` in the action's direction — carrying a slight perpendicular
    /// **bow** and a few-degrees **tilt** so it reads as a human hand, not a cursor — then lifts.
    /// All coordinates are normalized 0..1 trackpad space (clamped to `[lowerBound, upperBound]` when
    /// posed). Unlike the `.horizontal` / `.vertical` ping-pong axes, a stroke does not oscillate: it
    /// travels once, monotonically, from `from` toward `to`.
    struct Stroke: Equatable {
        /// How many fingertips press for this stroke (2 navigate, 3 open switcher, 4 open/dismiss launcher).
        var fingers: Int
        /// The centroid start point (where the hand presses down).
        var from: CGPoint
        /// The centroid end point (where the stroke arrives before the lift).
        var to: CGPoint
        /// An optional dwell at `to` (as a fraction of the stroke's own time) before the lift — used so a
        /// "land on the band" reads as a settle. `0` ⇒ stroke straight into the lift.
        var hold: Double

        init(fingers: Int, from: CGPoint, to: CGPoint, hold: Double = 0) {
            self.fingers = fingers
            self.from = from
            self.to = to
            self.hold = hold
        }
    }

    /// A full self-playing demonstration: an ordered list of directed `strokes` (each with its own
    /// finger count, so the journey changes hand shape — open 4 → navigate 2 → dismiss 4), separated by
    /// a **lift gap** in which the dots fade/absent before the next stroke presses down. The whole
    /// thing loops over one `2π` phase cycle. Pure / value-typed — `swift test`-able and side-effect-free.
    struct DemoGesture: Equatable {
        /// The directed strokes, performed in order then looped.
        var strokes: [Stroke]
        /// The relative time (per stroke) the hand spends lifted between strokes, before the next presses
        /// down — so each excursion reads as a separate decisive swipe, not one continuous drag.
        var liftGap: Double

        init(strokes: [Stroke], liftGap: Double = 0.45) {
            self.strokes = strokes
            self.liftGap = liftGap
        }
    }

    /// The in-surface gesture a band journey (or a canvas resolve) ends on / demonstrates — a directed
    /// excursion in one of four cardinal directions, or a `.lift` (rest-and-open, no excursion). Mirrors
    /// the `HubGesturePreview.BandInSurfaceGesture` semantics, lifted into MLX-free Core so the pose
    /// driver can build directed strokes from it. `.swipeHorizontal` is the dismiss-style horizontal
    /// excursion (a left-going stroke), kept as an alias of the canvas-dismiss default for parity with
    /// the existing Hub vocabulary.
    enum BandInSurfaceGesture: Equatable {
        /// Rest on the band and lift (Files / Clipboard land-and-open) — no directional excursion.
        case lift
        /// A downward two-finger resolve (the canvas commit default: top-middle → center-middle).
        case swipeDown
        /// An upward two-finger resolve (the canvas ignore default).
        case swipeUp
        /// A leftward two-finger resolve.
        case swipeLeft
        /// A rightward two-finger resolve.
        case swipeRight
        /// A horizontal two-finger resolve (the canvas dismiss default) — a leftward stroke.
        case swipeHorizontal
    }

    // MARK: - §11.1 Directed-stroke pose

    /// One demonstration frame for `gesture` at the continuous `phase`. The phase is mapped over one
    /// `2π` loop into the gesture's strokes (each stroke followed by a `liftGap`): within a stroke the
    /// centroid eases (ease-in-out) from `from` → `to`, the `fingers` fingertips fan out in the existing
    /// hand-like arc (with a perpendicular **bow** and a small **tilt** along the stroke direction so it
    /// reads as a hand), and `lifted` is `false`; in the gap between strokes `lifted` is `true` and `dots`
    /// is empty. All coordinates are clamped to `[lowerBound, upperBound]`. Returned metadata lets a
    /// preview drive its miniature in sync: which `strokeIndex` is playing, its `progress` 0..1, the live
    /// `fingerCount`, the `centroid`, and whether the hand is mid-`lifted`.
    nonisolated static func pose(
        phase: Double,
        gesture: DemoGesture
    ) -> (dots: [CGPoint], fingerCount: Int, centroid: CGPoint, strokeIndex: Int, progress: Double, lifted: Bool) {
        let restingCentroid = CGPoint(x: 0.5, y: 0.42)
        guard !gesture.strokes.isEmpty else {
            return (dots: [], fingerCount: 0, centroid: restingCentroid, strokeIndex: 0, progress: 0, lifted: true)
        }

        // One loop = N strokes, each of unit duration, plus a `liftGap` after each. Map phase → [0, total).
        let gap = max(0, gesture.liftGap)
        let perStroke = 1.0 + gap
        let total = perStroke * Double(gesture.strokes.count)

        let cycle = 2 * Double.pi
        var t = phase.truncatingRemainder(dividingBy: cycle) / cycle
        if t < 0 { t += 1 }
        var local = t * total                       // 0..total

        let index = min(gesture.strokes.count - 1, Int(local / perStroke))
        local -= Double(index) * perStroke          // 0..perStroke within this stroke
        let stroke = gesture.strokes[index]

        // The stroke occupies [0, 1] (with a trailing `hold` dwell at `to`), the lift occupies [1, perStroke].
        if local >= 1.0 {
            // Lifted gap between strokes: no dots, hand absent. Report progress at the stroke's end.
            return (dots: [], fingerCount: stroke.fingers, centroid: clampPoint(stroke.to),
                    strokeIndex: index, progress: 1, lifted: true)
        }

        // Within the stroke. A trailing `hold` fraction dwells at `to` (the settle before the lift).
        let hold = max(0, min(0.9, stroke.hold))
        let active = max(0.0001, 1.0 - hold)
        let rawProgress = min(1.0, local / active)          // 0..1 across the travel, then pinned at 1 for the hold
        let eased = easeInOut(rawProgress)

        let centroid = strokeCentroid(stroke: stroke, eased: eased)
        let dots = strokeFingertips(stroke: stroke, eased: eased, phase: phase)
        return (dots: dots, fingerCount: stroke.fingers, centroid: clampPoint(centroid),
                strokeIndex: index, progress: rawProgress, lifted: false)
    }

    /// The (unclamped) eased centroid along a stroke, with a slight perpendicular **bow** (a hand swings
    /// in a shallow arc, not a ruler-straight line). The bow peaks at mid-stroke and vanishes at both ends.
    nonisolated private static func strokeCentroid(stroke: Stroke, eased: CGFloat) -> CGPoint {
        let dx = stroke.to.x - stroke.from.x
        let dy = stroke.to.y - stroke.from.y
        let baseX = stroke.from.x + dx * eased
        let baseY = stroke.from.y + dy * eased

        // Perpendicular unit vector to the travel direction; bow magnitude peaks at mid-stroke.
        let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
        let perpX = -dy / length
        let perpY = dx / length
        let bow = 0.03 * sin(Double(eased) * Double.pi)     // 0 at ends, max in the middle
        return CGPoint(x: baseX + perpX * CGFloat(bow),
                       y: baseY + perpY * CGFloat(bow))
    }

    /// Fan the stroke's `fingers` fingertips around its eased centroid, tilting the fixed hand arc a few
    /// degrees toward the travel direction so the hand reads as reaching along the stroke (not a static
    /// blob). Same organic wobble + clamp as the attract loop.
    nonisolated private static func strokeFingertips(stroke: Stroke, eased: CGFloat, phase: Double) -> [CGPoint] {
        let centroid = strokeCentroid(stroke: stroke, eased: eased)
        let dx = stroke.to.x - stroke.from.x
        let dy = stroke.to.y - stroke.from.y
        // A few degrees of tilt along the travel direction (atan2 gives the stroke heading).
        let tilt = 0.12 * atan2(Double(dy), Double(dx))     // small fraction of the heading → a hand lean
        let cosT = CGFloat(cos(tilt))
        let sinT = CGFloat(sin(tilt))

        return arcOffsets(fingers: stroke.fingers).enumerated().map { index, offset in
            // Rotate the resting arc offset by the small tilt, then add the organic wobble.
            let ox = offset.0 * cosT - offset.1 * sinT
            let oy = offset.0 * sinT + offset.1 * cosT
            return CGPoint(x: clamp(centroid.x + ox + 0.010 * sin(phase * 1.7 + Double(index))),
                           y: clamp(centroid.y + oy + 0.010 * cos(phase * 1.3 + Double(index))))
        }
    }

    /// Standard smooth ease-in-out (smoothstep) over 0..1 — accelerate then decelerate, so a stroke reads
    /// as a deliberate human swipe rather than constant-velocity drift.
    nonisolated private static func easeInOut(_ t: CGFloat) -> CGFloat {
        let c = min(1, max(0, t))
        return c * c * (3 - 2 * c)
    }

    nonisolated private static func clampPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: clamp(p.x), y: clamp(p.y))
    }

    // MARK: - §11.1 Predefined directed-gesture builders

    /// The **window switcher** demonstration: open with a short **three-finger** swipe, then a few decisive
    /// **two-finger** directional scrubs (left → right) that step the highlight across the window grid.
    /// Encodes the real grammar — 3 fingers open the switcher, 2 fingers navigate within it.
    nonisolated static func switcherDemo() -> DemoGesture {
        let mid: CGFloat = 0.42
        let open = Stroke(fingers: 3, from: CGPoint(x: 0.30, y: mid), to: CGPoint(x: 0.62, y: mid))
        let scrubA = Stroke(fingers: 2, from: CGPoint(x: 0.30, y: mid), to: CGPoint(x: 0.70, y: mid))
        let scrubB = Stroke(fingers: 2, from: CGPoint(x: 0.30, y: mid), to: CGPoint(x: 0.70, y: mid))
        return DemoGesture(strokes: [open, scrubA, scrubB], liftGap: 0.5)
    }

    /// The **launcher** demonstration: a **four-finger** open swipe (the launch), then **two-finger** navigate
    /// strokes across the bands, then a **four-finger** dismiss swipe. Encodes the real grammar — 4 open /
    /// 2 navigate / 4 dismiss.
    nonisolated static func launcherOpen() -> DemoGesture {
        let mid: CGFloat = 0.42
        let open = Stroke(fingers: 4, from: CGPoint(x: 0.22, y: mid), to: CGPoint(x: 0.58, y: mid))
        let navA = Stroke(fingers: 2, from: CGPoint(x: 0.32, y: mid), to: CGPoint(x: 0.70, y: mid))
        let navB = Stroke(fingers: 2, from: CGPoint(x: 0.70, y: mid), to: CGPoint(x: 0.34, y: mid))
        let dismiss = Stroke(fingers: 4, from: CGPoint(x: 0.62, y: mid), to: CGPoint(x: 0.24, y: mid))
        return DemoGesture(strokes: [open, navA, navB, dismiss], liftGap: 0.5)
    }

    /// A **band journey** demonstration: a **four-finger** open, **two-finger** traverse strokes across to the
    /// target band (the final traverse centroid lands at `bandFraction` across the pad), then the band's
    /// **two-finger** in-surface stroke (`inSurface` — e.g. `.swipeDown` for an AI commit, or `.lift` to rest
    /// and open). Encodes the real grammar — 4 open / 2 traverse / 2 act-within.
    nonisolated static func bandJourney(
        bandFraction: CGFloat,
        inSurface: BandInSurfaceGesture
    ) -> DemoGesture {
        let mid: CGFloat = 0.42
        let land = max(lowerBound, min(upperBound, lowerBound + (upperBound - lowerBound) * bandFraction))

        // Four-finger open in from the left.
        let open = Stroke(fingers: 4, from: CGPoint(x: lowerBound, y: mid), to: CGPoint(x: (lowerBound + land) / 2, y: mid))
        // Two-finger traverse across to the target band, settling on it.
        let traverse = Stroke(fingers: 2, from: CGPoint(x: (lowerBound + land) / 2, y: mid),
                              to: CGPoint(x: land, y: mid), hold: 0.25)

        var strokes = [open, traverse]
        if let act = inSurfaceStroke(inSurface, at: land, mid: mid) {
            strokes.append(act)
        }
        return DemoGesture(strokes: strokes, liftGap: 0.5)
    }

    /// A standalone **canvas resolve** demonstration: a single decisive **two-finger** directed swipe in `dir`
    /// (e.g. `.swipeDown` = top-middle → center-middle), carrying the hand angle/bow, then a lift and a loop.
    nonisolated static func canvasResolve(_ dir: BandInSurfaceGesture) -> DemoGesture {
        let center = CGPoint(x: 0.5, y: 0.5)
        let stroke = inSurfaceStroke(dir, at: center.x, mid: center.y)
            ?? Stroke(fingers: 2, from: center, to: center)
        return DemoGesture(strokes: [stroke], liftGap: 0.6)
    }

    /// The directed two-finger stroke for an in-surface excursion, anchored at the landing column `land`
    /// (X) and resting row `mid` (Y). `.lift` has no directional stroke (returns nil — the journey simply
    /// rests on the band). Directions stroke from one edge of the safe pad toward the centre/landing.
    nonisolated private static func inSurfaceStroke(_ g: BandInSurfaceGesture, at land: CGFloat, mid: CGFloat) -> Stroke? {
        let lo = lowerBound
        let hi = upperBound
        switch g {
        case .lift:
            return nil
        case .swipeDown:
            // Top-middle → center: a downward commit.
            return Stroke(fingers: 2, from: CGPoint(x: land, y: lo), to: CGPoint(x: land, y: mid))
        case .swipeUp:
            return Stroke(fingers: 2, from: CGPoint(x: land, y: hi), to: CGPoint(x: land, y: mid))
        case .swipeLeft, .swipeHorizontal:
            let from = min(hi, land + 0.30)
            return Stroke(fingers: 2, from: CGPoint(x: from, y: mid), to: CGPoint(x: max(lo, land - 0.10), y: mid))
        case .swipeRight:
            let from = max(lo, land - 0.30)
            return Stroke(fingers: 2, from: CGPoint(x: from, y: mid), to: CGPoint(x: min(hi, land + 0.10), y: mid))
        }
    }
}
