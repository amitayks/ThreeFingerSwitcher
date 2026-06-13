import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for the pure anchored-positional navigation core (change `positional-navigation`): the
/// per-axis zone state machine, footprint-scaled anchor, the navigator, the eased repeat cadence, and
/// the `TouchFrame.footprintSpread` accessor. All AppKit-free and deterministic.
final class PositionalNavigatorTests: XCTestCase {

    // MARK: - AxisZone (out-and-back, hold, re-arm, flip)

    func testOutAndBackEmitsExactlyOneStep() {
        var z = AxisZone(inner: 0.2, outer: 0.5)
        XCTAssertEqual(z.feed(0.1), 0)            // inside outer: nothing
        XCTAssertEqual(z.feed(0.6), 1)            // cross outer: one step
        XCTAssertEqual(z.heldSign, 1)
        XCTAssertEqual(z.feed(0.7), 0)            // still held: no second step
        XCTAssertEqual(z.feed(0.15), 0)           // back inside inner: re-arm, no step
        XCTAssertEqual(z.heldSign, 0)
        XCTAssertEqual(z.feed(0.6), 1)            // out again: a fresh step
    }

    func testHoldSustainsHeldSignWithoutRepeating() {
        var z = AxisZone(inner: 0.2, outer: 0.5)
        XCTAssertEqual(z.feed(-0.6), -1)          // cross low side
        XCTAssertEqual(z.heldSign, -1)
        // Held beyond outer for many frames: the zone emits no further discrete steps (the controller
        // auto-repeats off heldSign instead).
        for _ in 0..<10 { XCTAssertEqual(z.feed(-0.8), 0) }
        XCTAssertEqual(z.heldSign, -1)
    }

    func testReturnBetweenInnerAndOuterDoesNotReArm() {
        var z = AxisZone(inner: 0.2, outer: 0.5)
        _ = z.feed(0.6)                            // held +1
        XCTAssertEqual(z.feed(0.35), 0)           // between inner and outer: still held, no re-arm
        XCTAssertEqual(z.heldSign, 1)
        XCTAssertEqual(z.feed(0.6), 0)            // out again without re-arming: NO new step
    }

    func testFastFlipStepsTheOtherWay() {
        var z = AxisZone(inner: 0.2, outer: 0.5)
        XCTAssertEqual(z.feed(0.6), 1)            // held +1
        XCTAssertEqual(z.feed(-0.6), -1)          // flip straight past the opposite outer
        XCTAssertEqual(z.heldSign, -1)
    }

    // MARK: - PositionalAnchor (footprint scaling + fallback)

    func testAnchorScalesByFootprint() {
        // A wider footprint needs proportionally more travel for the same normalized offset.
        let narrow = PositionalAnchor(center: CGPoint(x: 0.5, y: 0.5), spread: 0.1,
                                      footprintFactor: 1.0, fallbackScale: 0.2)
        let wide = PositionalAnchor(center: CGPoint(x: 0.5, y: 0.5), spread: 0.2,
                                    footprintFactor: 1.0, fallbackScale: 0.2)
        // Same physical centroid move (+0.1 in x): narrow → offset 1.0, wide → offset 0.5.
        XCTAssertEqual(narrow.offset(for: CGPoint(x: 0.6, y: 0.5)).x, 1.0, accuracy: 1e-9)
        XCTAssertEqual(wide.offset(for: CGPoint(x: 0.6, y: 0.5)).x, 0.5, accuracy: 1e-9)
    }

    func testAnchorFallbackWhenNoFootprint() {
        let a = PositionalAnchor(center: .zero, spread: nil, footprintFactor: 1.2, fallbackScale: 0.1)
        XCTAssertEqual(a.scale, 0.1, accuracy: 1e-9)         // fixed fallback
        let b = PositionalAnchor(center: .zero, spread: 0.0, footprintFactor: 1.2, fallbackScale: 0.1)
        XCTAssertEqual(b.scale, 0.1, accuracy: 1e-9)         // degenerate spread → fallback
    }

    // MARK: - PositionalNavigator (integration + re-anchor)

    func testNavigatorEmitsStepAndHeldOnFeed() {
        var nav = PositionalNavigator(footprintFactor: 1.0, fallbackScale: 0.1, inner: 0.2, outer: 0.5)
        nav.reanchor(center: CGPoint(x: 0.5, y: 0.5), spread: 0.1)   // scale = 0.1
        // Move +0.06 in x (offset 0.6 > outer) → one item step right, held +1; y untouched.
        let out = nav.feed(centroid: CGPoint(x: 0.56, y: 0.5))
        XCTAssertEqual(out.stepX, 1)
        XCTAssertEqual(out.heldX, 1)
        XCTAssertEqual(out.stepY, 0)
        XCTAssertEqual(out.heldY, 0)
    }

    func testReanchorResetsStateAndEmitsNoStep() {
        var nav = PositionalNavigator(footprintFactor: 1.0, fallbackScale: 0.1, inner: 0.2, outer: 0.5)
        nav.reanchor(center: CGPoint(x: 0.5, y: 0.5), spread: 0.1)
        _ = nav.feed(centroid: CGPoint(x: 0.56, y: 0.5))            // held +1
        // Re-anchor at the held position: state resets and the very same centroid now reads offset ~0.
        nav.reanchor(center: CGPoint(x: 0.56, y: 0.5), spread: 0.1)
        let out = nav.feed(centroid: CGPoint(x: 0.56, y: 0.5))
        XCTAssertEqual(out, PositionalNavigator.Output(stepX: 0, stepY: 0, heldX: 0, heldY: 0))
    }

    func testRetreatFromPeakRecentersAndStopsRepeat() {
        // reArmBackoff: while auto-repeating, a back-move retreating from the peak by ≥ backoff snaps the
        // center to the finger (offset → ~0) and clears the held sign, stopping the repeat.
        var nav = PositionalNavigator(footprintFactor: 1.0, fallbackScale: 0.1, inner: 0.2, outer: 0.5)
        nav.reArmBackoff = 0.2
        nav.reanchor(center: CGPoint(x: 0.5, y: 0.5), spread: 0.1)   // scale 0.1
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.56, y: 0.5)).stepX, 1)   // offset +0.6 → step, held +1
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.56, y: 0.5)).heldX, 1)   // held (peak 0.6)

        // A small back-move (offset 0.55, retreat 0.05 < 0.2) does NOT re-center — still held.
        let small = nav.feed(centroid: CGPoint(x: 0.555, y: 0.5))
        XCTAssertEqual(small.heldX, 1, "a back-move smaller than the back-off keeps the repeat")
        XCTAssertEqual(small.stepX, 0)

        // A back-move past the back-off (offset 0.4, retreat 0.6→0.4 = 0.2 ≥ 0.2) re-centers and stops.
        let stop = nav.feed(centroid: CGPoint(x: 0.54, y: 0.5))
        XCTAssertEqual(stop.heldX, 0, "the center snapped to the finger → repeat stopped")
        XCTAssertEqual(stop.stepX, 0)

        // Re-armed at the new center (0.54): the same point reads offset ~0, and a fresh nudge steps again.
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.54, y: 0.5)).heldX, 0)
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.60, y: 0.5)).stepX, 1, "a fresh nudge from the new center steps")
    }

    func testRetreatRecenterDisabledWhenBackoffZero() {
        // With reArmBackoff 0 the old behavior holds: only the inner deadzone re-arms.
        var nav = PositionalNavigator(footprintFactor: 1.0, fallbackScale: 0.1, inner: 0.2, outer: 0.5)
        nav.reArmBackoff = 0
        nav.reanchor(center: CGPoint(x: 0.5, y: 0.5), spread: 0.1)
        _ = nav.feed(centroid: CGPoint(x: 0.6, y: 0.5))                     // offset 1.0 → held
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.54, y: 0.5)).heldX, 1, "still held; no retreat re-center")
    }

    // MARK: - Position-tracking (the launcher padding box + edge-margin acceleration)

    private func trackingNav(step: CGFloat = 0.5, radius: CGFloat = 2.0, edgeMargin: CGFloat = 0) -> PositionalNavigator {
        var nav = PositionalNavigator(footprintFactor: 1.0, fallbackScale: 0.1,
                                      x: AxisZone(mode: .positionTracking, step: step, radius: radius),
                                      y: AxisZone(mode: .positionTracking, step: step, radius: radius))
        nav.edgeMargin = edgeMargin
        nav.reanchor(center: CGPoint(x: 0.5, y: 0.5), spread: 0.1)   // scale 0.1 → offset = travel/0.1
        return nav
    }

    func testPositionTrackingFollowsTheFingerBothWays() {
        var nav = trackingNav()
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.65, y: 0.5)).stepX, 3, "offset +1.5 → index 3 → +3 steps")
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.65, y: 0.5)).stepX, 0, "holding the position emits no more")
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.50, y: 0.5)).stepX, -3, "back to center → −3 steps")
    }

    func testPositionTrackingMarginAccelerates() {
        var nav = trackingNav(step: 0.5, radius: 2.0)
        let out = nav.feed(centroid: CGPoint(x: 0.72, y: 0.5))   // offset +2.2 ≥ radius 2.0 → margin
        XCTAssertEqual(out.heldX, 1, "leaving the box accelerates (held +1)")
        XCTAssertEqual(out.stepX, 4, "index snaps to the box edge (maxIndex = radius/step = 4)")
    }

    func testPositionTrackingEdgeBandAcceleratesInsideBox() {
        var nav = trackingNav(step: 0.5, radius: 5.0, edgeMargin: 0.10)   // box radius won't trigger
        // Re-anchor near the right edge, then push toward the border but stay inside the box.
        nav.reanchor(center: CGPoint(x: 0.85, y: 0.5), spread: 0.1)
        let out = nav.feed(centroid: CGPoint(x: 0.93, y: 0.5))   // offset +0.8 (in box) but centroid ≥ 0.90
        XCTAssertEqual(out.heldX, 1, "the fixed edge band accelerates even inside the box radius")
    }

    func testFeedBeforeAnchorIsNoOp() {
        var nav = PositionalNavigator(footprintFactor: 1.0, fallbackScale: 0.1, inner: 0.2, outer: 0.5)
        XCTAssertEqual(nav.feed(centroid: CGPoint(x: 0.9, y: 0.9)),
                       PositionalNavigator.Output(stepX: 0, stepY: 0, heldX: 0, heldY: 0))
    }

    // MARK: - RepeatCadence (eased curve)

    func testCadenceStartsAtInitialDelayAndConvergesToFloor() {
        let initial = 0.22, floor = 0.03, ramp = 1.2
        XCTAssertEqual(RepeatCadence.interval(dwellElapsed: 0, initialDelay: initial, floor: floor, rampTime: ramp),
                       initial, accuracy: 1e-9)
        XCTAssertEqual(RepeatCadence.interval(dwellElapsed: ramp, initialDelay: initial, floor: floor, rampTime: ramp),
                       floor, accuracy: 1e-9)
        XCTAssertEqual(RepeatCadence.interval(dwellElapsed: 99, initialDelay: initial, floor: floor, rampTime: ramp),
                       floor, accuracy: 1e-9)
    }

    func testCadenceIsMonotonicNonIncreasingAndNeverBelowFloor() {
        let initial = 0.22, floor = 0.03, ramp = 1.2
        var previous = RepeatCadence.interval(dwellElapsed: 0, initialDelay: initial, floor: floor, rampTime: ramp)
        var t = 0.0
        while t <= ramp + 0.5 {
            let v = RepeatCadence.interval(dwellElapsed: t, initialDelay: initial, floor: floor, rampTime: ramp)
            XCTAssertLessThanOrEqual(v, previous + 1e-12)   // non-increasing
            XCTAssertGreaterThanOrEqual(v, floor - 1e-12)   // never below floor
            previous = v
            t += 0.05
        }
    }

    // MARK: - TouchFrame.footprintSpread

    func testFootprintSpreadFromContactPoints() {
        // Two points at x = 0.4 and 0.6 (centroid x = 0.5): each is 0.1 from centroid → mean 0.1.
        let f = TouchFrame(testContactPoints: [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)])
        XCTAssertEqual(f.footprintSpread ?? -1, 0.1, accuracy: 1e-9)
    }

    func testFootprintSpreadNilWhenNoPoints() {
        let f = TouchFrame(testFingerCount: 4, centroid: CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(f.footprintSpread)               // count-only frame → caller's fallback
    }

    func testFootprintSpreadZeroForSingleContact() {
        let f = TouchFrame(testContactPoints: [CGPoint(x: 0.5, y: 0.5)])
        XCTAssertEqual(f.footprintSpread ?? -1, 0, accuracy: 1e-9)   // degenerate → fallback path
    }
}
