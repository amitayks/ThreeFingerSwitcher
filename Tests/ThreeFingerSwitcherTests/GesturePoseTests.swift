import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for the shared `GesturePose` driver (Sources/ThreeFingerSwitcher/Gesture/GesturePose.swift).
/// It generalizes the wizard's attract loop, so the contract is: every pose stays on the pad for
/// 2/3/4 fingers, horizontal and vertical sweep on their own axes, a scripted path visits its
/// keyframes in order and loops, and the 3-finger horizontal case reproduces the prior
/// `attractPose` exactly (onboarding must look identical).
final class GesturePoseTests: XCTestCase {

    /// Sample several full cycles of phase at the shared step.
    private func sweep(_ body: (Double) -> Void) {
        var phase = 0.0
        while phase < 8 * Double.pi {
            body(phase)
            phase += GesturePose.phaseStep
        }
    }

    // MARK: - Bounds

    func testPosesStayInBoundsForTwoThreeAndFourFingers() {
        for fingers in 2...4 {
            for axis in axesUnderTest() {
                sweep { phase in
                    let pose = GesturePose.pose(phase: phase, fingers: fingers, axis: axis)
                    XCTAssertEqual(pose.dots.count, fingers,
                                   "\(fingers) fingers should produce \(fingers) fingertips")
                    for dot in pose.dots {
                        XCTAssertTrue((GesturePose.lowerBound...GesturePose.upperBound).contains(dot.x),
                                      "dot x \(dot.x) out of pad bounds (fingers \(fingers))")
                        XCTAssertTrue((GesturePose.lowerBound...GesturePose.upperBound).contains(dot.y),
                                      "dot y \(dot.y) out of pad bounds (fingers \(fingers))")
                    }
                }
            }
        }
    }

    private func axesUnderTest() -> [GesturePose.Axis] {
        [.horizontal,
         .vertical,
         .scripted([GesturePose.Keyframe(x: 0.1, y: 0.5),
                    GesturePose.Keyframe(x: 0.9, y: 0.5),
                    GesturePose.Keyframe(x: 0.5, y: 0.9)])]
    }

    // MARK: - Axis travel

    func testHorizontalSweepsXNotY() {
        var xs: Set<Int> = []
        var ys: Set<Int> = []
        sweep { phase in
            let c = GesturePose.pose(phase: phase, fingers: 3, axis: .horizontal).centroid
            xs.insert(Int((c.x * 10).rounded()))
            ys.insert(Int((c.y * 10).rounded()))
        }
        // Horizontal's dominant travel is on X (≈ ±0.40) and only a gentle drift on Y (≈ ±0.05).
        XCTAssertGreaterThan(xs.count, ys.count,
                             "horizontal centroid must travel farther on X than on Y")
        XCTAssertGreaterThanOrEqual(xs.count, 5, "X should span much of the pad")
    }

    func testVerticalSweepsYNotX() {
        var xs: Set<Int> = []
        var ys: Set<Int> = []
        sweep { phase in
            let c = GesturePose.pose(phase: phase, fingers: 3, axis: .vertical).centroid
            xs.insert(Int((c.x * 10).rounded()))
            ys.insert(Int((c.y * 10).rounded()))
        }
        // Vertical is the mirror image: the dominant travel is on Y.
        XCTAssertGreaterThan(ys.count, xs.count,
                             "vertical centroid must travel farther on Y than on X")
        XCTAssertGreaterThanOrEqual(ys.count, 5, "Y should span much of the pad")
    }

    // MARK: - Scripted path

    func testScriptedVisitsKeyframesInOrderAndLoops() {
        let frames = [GesturePose.Keyframe(x: 0.1, y: 0.2),
                      GesturePose.Keyframe(x: 0.8, y: 0.3),
                      GesturePose.Keyframe(x: 0.4, y: 0.9)]
        let axis = GesturePose.Axis.scripted(frames)
        let cycle = 2 * Double.pi

        // The path begins exactly on the first keyframe and reaches each subsequent keyframe at its
        // even fraction of the loop (legCount == keyframes.count, the last leg wraps to the first).
        let legCount = Double(frames.count)
        for (index, frame) in frames.enumerated() {
            let phase = cycle * Double(index) / legCount
            let c = GesturePose.pose(phase: phase, fingers: 3, axis: axis).centroid
            XCTAssertEqual(c.x, frame.centroid.x, accuracy: 1e-9,
                           "keyframe \(index) x reached at its fraction of the loop")
            XCTAssertEqual(c.y, frame.centroid.y, accuracy: 1e-9,
                           "keyframe \(index) y reached at its fraction of the loop")
        }

        // The order is monotone within the first leg: a sample partway between k0 and k1 lies
        // strictly between them on X (0.1 → 0.8 is increasing).
        let mid = GesturePose.pose(phase: cycle * 0.5 / legCount, fingers: 3, axis: axis).centroid
        XCTAssertGreaterThan(mid.x, frames[0].centroid.x)
        XCTAssertLessThan(mid.x, frames[1].centroid.x)

        // It loops: phase 0 and phase + one full cycle land on the same point (back at k0).
        let start = GesturePose.pose(phase: 0, fingers: 3, axis: axis).centroid
        let looped = GesturePose.pose(phase: cycle, fingers: 3, axis: axis).centroid
        XCTAssertEqual(start.x, looped.x, accuracy: 1e-9, "the scripted path loops on X")
        XCTAssertEqual(start.y, looped.y, accuracy: 1e-9, "the scripted path loops on Y")
    }

    func testSingleKeyframeScriptRestsThere() {
        let axis = GesturePose.Axis.scripted([GesturePose.Keyframe(x: 0.3, y: 0.7)])
        for phase in stride(from: 0.0, to: 4 * Double.pi, by: 0.5) {
            let c = GesturePose.pose(phase: phase, fingers: 3, axis: axis).centroid
            XCTAssertEqual(c.x, 0.3, accuracy: 1e-9)
            XCTAssertEqual(c.y, 0.7, accuracy: 1e-9)
        }
    }

    // MARK: - Onboarding parity

    func testThreeFingerHorizontalMatchesPriorAttractPose() {
        // The exact output the wizard produced before the lift — recomputed inline here so this
        // test pins the contract independently of the (now-thin) wizard wrapper.
        func legacyAttractPose(phase: Double) -> (centroid: CGPoint, dots: [CGPoint]) {
            let x = 0.5 + 0.40 * sin(phase)
            let y = 0.42 + 0.05 * sin(phase * 0.63)
            let offsets: [(CGFloat, CGFloat)] = [(-0.16, 0.10), (0, 0.17), (0.16, 0.10)]
            let dots = offsets.enumerated().map { index, offset in
                CGPoint(x: min(0.95, max(0.05, x + offset.0 + 0.012 * sin(phase * 1.7 + Double(index)))),
                        y: min(0.95, max(0.05, y + offset.1 + 0.012 * cos(phase * 1.3 + Double(index)))))
            }
            return (CGPoint(x: x, y: y), dots)
        }

        for phase in stride(from: 0.0, to: 6 * Double.pi, by: 0.137) {
            let legacy = legacyAttractPose(phase: phase)
            let shared = GesturePose.pose(phase: phase, fingers: 3, axis: .horizontal)
            XCTAssertEqual(shared.centroid.x, legacy.centroid.x, accuracy: 1e-12)
            XCTAssertEqual(shared.centroid.y, legacy.centroid.y, accuracy: 1e-12)
            XCTAssertEqual(shared.dots.count, legacy.dots.count)
            for (a, b) in zip(shared.dots, legacy.dots) {
                XCTAssertEqual(a.x, b.x, accuracy: 1e-12)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-12)
            }
        }
    }

    func testWizardWrapperStillMatchesSharedDriver() {
        for phase in stride(from: 0.0, to: 4 * Double.pi, by: 0.2) {
            let wrapped = FirstTouchWizardModel.attractPose(phase: phase)
            let shared = GesturePose.pose(phase: phase, fingers: 3, axis: .horizontal)
            XCTAssertEqual(wrapped.centroid.x, shared.centroid.x, accuracy: 1e-12)
            XCTAssertEqual(wrapped.centroid.y, shared.centroid.y, accuracy: 1e-12)
            for (a, b) in zip(wrapped.dots, shared.dots) {
                XCTAssertEqual(a.x, b.x, accuracy: 1e-12)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-12)
            }
        }
        XCTAssertEqual(FirstTouchWizardModel.attractPhaseStep, GesturePose.phaseStep)
    }

    // MARK: - §11.1 Directed-stroke pose (v2)

    /// Sample a demo gesture across two full loops at a fine step, calling `body` per frame.
    private func sweepGesture(_ gesture: GesturePose.DemoGesture, _ body: ((dots: [CGPoint], fingerCount: Int, centroid: CGPoint, strokeIndex: Int, progress: Double, lifted: Bool)) -> Void) {
        var phase = 0.0
        // A fine step so every stroke and gap is sampled densely.
        let step = (2 * Double.pi) / 600.0
        while phase < 4 * Double.pi {
            body(GesturePose.pose(phase: phase, gesture: gesture))
            phase += step
        }
    }

    func testStrokeTravelsDecisivelyFromTo() {
        // A single rightward stroke: while pressed (not lifted) the centroid X must increase
        // monotonically from `from` toward `to` — a decisive directed stroke, never oscillating back.
        let stroke = GesturePose.Stroke(fingers: 2, from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.8, y: 0.5))
        let gesture = GesturePose.DemoGesture(strokes: [stroke], liftGap: 0.4)

        var lastX: CGFloat = -1
        var sawStart = false
        var sawEnd = false
        sweepGesture(gesture) { frame in
            guard !frame.lifted else { lastX = -1; return }   // reset across the lift gap
            // X is non-decreasing across the pressed portion of the stroke.
            if lastX >= 0 {
                XCTAssertGreaterThanOrEqual(frame.centroid.x, lastX - 1e-9,
                                            "a directed stroke must not oscillate backward on X")
            }
            lastX = frame.centroid.x
            if frame.progress < 0.02 { sawStart = true }
            if frame.progress > 0.98 { sawEnd = true }
        }
        XCTAssertTrue(sawStart, "the stroke should be sampled near its start")
        XCTAssertTrue(sawEnd, "the stroke should be sampled near its end")
    }

    func testPerSegmentFingerCountsSwitcherDemo() {
        // switcherDemo: open with 3, then two 2-finger scrubs.
        let g = GesturePose.switcherDemo()
        XCTAssertEqual(g.strokes.map(\.fingers), [3, 2, 2],
                       "switcherDemo opens with 3 fingers then navigates with 2")

        // The live finger count reported by `pose` matches the active stroke's count (while pressed).
        var seenForIndex: [Int: Set<Int>] = [:]
        sweepGesture(g) { frame in
            seenForIndex[frame.strokeIndex, default: []].insert(frame.fingerCount)
        }
        XCTAssertEqual(seenForIndex[0], [3])
        XCTAssertEqual(seenForIndex[1], [2])
        XCTAssertEqual(seenForIndex[2], [2])
    }

    func testPerSegmentFingerCountsLauncherOpen() {
        // launcherOpen: 4 open → 2 navigate → 2 navigate → 4 dismiss.
        let g = GesturePose.launcherOpen()
        XCTAssertEqual(g.strokes.map(\.fingers), [4, 2, 2, 4],
                       "launcherOpen opens with 4, navigates with 2, dismisses with 4")
    }

    func testBandJourneyEncodesGrammarAndLands() {
        let g = GesturePose.bandJourney(bandFraction: 0.66, inSurface: .swipeDown)
        // 4-finger open, 2-finger traverse, 2-finger in-surface act.
        XCTAssertEqual(g.strokes.map(\.fingers), [4, 2, 2])
        // The traverse settles at `bandFraction` across the safe pad.
        let expectedLand = GesturePose.lowerBound + (GesturePose.upperBound - GesturePose.lowerBound) * 0.66
        XCTAssertEqual(g.strokes[1].to.x, expectedLand, accuracy: 1e-9,
                       "the traverse lands proportionally across the pad at bandFraction")
    }

    func testBandJourneyLiftHasNoInSurfaceStroke() {
        // A `.lift` journey rests on the band — no third directional stroke.
        let g = GesturePose.bandJourney(bandFraction: 1.0, inSurface: .lift)
        XCTAssertEqual(g.strokes.map(\.fingers), [4, 2],
                       "a lift journey is open + traverse only (rest-and-open, no excursion stroke)")
    }

    func testCanvasResolveDownIsTwoFingerDirected() {
        // A canvas commit: a single two-finger downward stroke from top-middle toward center.
        let g = GesturePose.canvasResolve(.swipeDown)
        XCTAssertEqual(g.strokes.count, 1)
        let s = g.strokes[0]
        XCTAssertEqual(s.fingers, 2, "the canvas resolve is a two-finger excursion")
        XCTAssertLessThan(s.from.y, s.to.y, "swipeDown strokes from a higher point downward (top → center)")
        XCTAssertEqual(s.from.x, s.to.x, accuracy: 1e-9, "a vertical resolve keeps X fixed")
    }

    func testLiftGapsEmitLifted() {
        // Across a multi-stroke gesture there must be frames where the hand is lifted (dots empty).
        let g = GesturePose.launcherOpen()
        var sawLifted = false
        var sawPressed = false
        sweepGesture(g) { frame in
            if frame.lifted {
                sawLifted = true
                XCTAssertTrue(frame.dots.isEmpty, "a lifted frame emits no dots")
            } else {
                sawPressed = true
                XCTAssertFalse(frame.dots.isEmpty, "a pressed frame shows fingertips")
            }
        }
        XCTAssertTrue(sawLifted, "lift gaps between strokes must emit lifted frames")
        XCTAssertTrue(sawPressed, "strokes must emit pressed frames with dots")
    }

    func testAllDotsWithinBoundsForEveryBuilder() {
        let builders: [GesturePose.DemoGesture] = [
            GesturePose.switcherDemo(),
            GesturePose.launcherOpen(),
            GesturePose.bandJourney(bandFraction: 0.0, inSurface: .lift),
            GesturePose.bandJourney(bandFraction: 1.0, inSurface: .swipeDown),
            GesturePose.bandJourney(bandFraction: 0.5, inSurface: .swipeHorizontal),
            GesturePose.canvasResolve(.swipeUp),
            GesturePose.canvasResolve(.swipeLeft),
            GesturePose.canvasResolve(.swipeRight)
        ]
        for g in builders {
            sweepGesture(g) { frame in
                for dot in frame.dots {
                    XCTAssertTrue((GesturePose.lowerBound...GesturePose.upperBound).contains(dot.x),
                                  "dot x \(dot.x) out of bounds")
                    XCTAssertTrue((GesturePose.lowerBound...GesturePose.upperBound).contains(dot.y),
                                  "dot y \(dot.y) out of bounds")
                }
                XCTAssertTrue((GesturePose.lowerBound...GesturePose.upperBound).contains(frame.centroid.x))
                XCTAssertTrue((GesturePose.lowerBound...GesturePose.upperBound).contains(frame.centroid.y))
            }
        }
    }

    func testGestureLoops() {
        // The directed demo loops: phase 0 and phase + 2π land on the same frame.
        let g = GesturePose.launcherOpen()
        let cycle = 2 * Double.pi
        for base in stride(from: 0.0, to: cycle, by: cycle / 50) {
            let a = GesturePose.pose(phase: base, gesture: g)
            let b = GesturePose.pose(phase: base + cycle, gesture: g)
            XCTAssertEqual(a.centroid.x, b.centroid.x, accuracy: 1e-9, "demo loops on centroid X")
            XCTAssertEqual(a.centroid.y, b.centroid.y, accuracy: 1e-9, "demo loops on centroid Y")
            XCTAssertEqual(a.fingerCount, b.fingerCount, "demo loops on finger count")
            XCTAssertEqual(a.lifted, b.lifted, "demo loops on lift state")
            XCTAssertEqual(a.strokeIndex, b.strokeIndex, "demo loops on stroke index")
        }
    }

    func testEmptyGestureIsLifted() {
        let g = GesturePose.DemoGesture(strokes: [], liftGap: 0.5)
        let frame = GesturePose.pose(phase: 1.2, gesture: g)
        XCTAssertTrue(frame.lifted)
        XCTAssertTrue(frame.dots.isEmpty)
        XCTAssertEqual(frame.fingerCount, 0)
    }

    func testStrokeAdvancesAcrossSegmentsInOrder() {
        // The strokeIndex advances 0 → last across one loop (and the journey changes finger count).
        let g = GesturePose.launcherOpen()
        var indicesSeen: [Int] = []
        var phase = 0.0
        let step = (2 * Double.pi) / 800.0
        while phase < 2 * Double.pi {
            let idx = GesturePose.pose(phase: phase, gesture: g).strokeIndex
            if indicesSeen.last != idx { indicesSeen.append(idx) }
            phase += step
        }
        XCTAssertEqual(indicesSeen, [0, 1, 2, 3],
                       "strokes play in order across the loop")
    }
}
