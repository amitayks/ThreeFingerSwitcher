import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure `LauncherTourEngine` (Sources/ThreeFingerSwitcher/Gesture/LauncherTourEngine.swift):
/// the settings-driven odometer behind the Hub launcher/band previews. Contract: a four-finger horizontal
/// travel that crosses the activation threshold fires `.activate`; once activated, two-finger travel emits
/// item/band steps with carry at the configured distances; a contact-count change re-baselines (no phantom
/// step), including the real four→two open→navigate hand-off; a full lift ends an active tour and never fires.
final class LauncherTourEngineTests: XCTestCase {

    private func makeEngine() -> LauncherTourEngine {
        LauncherTourEngine(activationThreshold: 0.05, itemStep: 0.04, bandStep: 0.09)
    }

    // MARK: - Activation

    func testFourFingerTravelActivatesAtThreshold() {
        var engine = makeEngine()
        // Land four fingers (re-baseline, no intent yet), then travel just under, then past the threshold.
        XCTAssertEqual(engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: true), [])
        XCTAssertEqual(engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.33, y: 0.5), onBandList: true), [],
                       "under the threshold → no activation yet")
        XCTAssertEqual(engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.36, y: 0.5), onBandList: true),
                       [.activate], "crossing the threshold fires .activate once")
        XCTAssertTrue(engine.isActive)
    }

    func testSubFourFingersNeverActivate() {
        var engine = makeEngine()
        _ = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.20, y: 0.5), onBandList: true)
        // A long two-finger sweep before any activation must NOT open the launcher.
        let intents = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.80, y: 0.5), onBandList: true)
        XCTAssertEqual(intents, [])
        XCTAssertFalse(engine.isActive)
    }

    // MARK: - Navigation odometer (with carry)

    func testActivatedHorizontalEmitsItemStepsWithCarry() {
        var engine = makeEngine()
        // Activate first.
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: false)
        XCTAssertEqual(engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.40, y: 0.5), onBandList: false), [.activate])
        // Hand off to two fingers (re-baseline at 0.40), then scrub right by ~3 item steps (0.04 each).
        XCTAssertEqual(engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.5), onBandList: false), [])
        let intents = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.53, y: 0.5), onBandList: false)
        XCTAssertEqual(intents, [.stepHorizontal(1), .stepHorizontal(1), .stepHorizontal(1)],
                       "0.13 of travel at a 0.04 step = 3 steps, with the 0.01 remainder carried")
    }

    func testVerticalUsesBandStepOnTheListAndItemStepInTheGrid() {
        var engine = makeEngine()
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: true)
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.40, y: 0.5), onBandList: true)
        _ = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.5), onBandList: true)   // re-baseline
        // On the band list (bandStep 0.09): moving DOWN the pad (y up) by 0.10 → one next-band step.
        XCTAssertEqual(engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.60), onBandList: true),
                       [.stepVertical(-1)], "down the pad = next band; one bandStep crossing")
        // In the grid (itemStep 0.04): the same kind of move now steps rows at the finer distance.
        _ = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.60), onBandList: false)   // re-baseline (focus flip is a fresh frame)
        let rows = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.69), onBandList: false)
        XCTAssertEqual(rows, [.stepVertical(-1), .stepVertical(-1)], "0.09 of travel at a 0.04 row step = 2 steps")
    }

    func testUpOnThePadStepsToPreviousBand() {
        var engine = makeEngine()
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: true)
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.40, y: 0.5), onBandList: true)
        _ = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.50), onBandList: true)
        // Up the pad (y decreasing) = previous band = stepVertical(+1).
        XCTAssertEqual(engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.40), onBandList: true),
                       [.stepVertical(1)])
    }

    // MARK: - Re-baseline + end

    func testCountChangeReBaselinesWithoutPhantomStep() {
        var engine = makeEngine()
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: false)
        XCTAssertEqual(engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.45, y: 0.5), onBandList: false), [.activate])
        // The four→two hand-off lands the two fingers at a DIFFERENT x; it must not emit a step.
        XCTAssertEqual(engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.10, y: 0.5), onBandList: false), [],
                       "a contact-count change re-baselines — no phantom step across the hand-off")
    }

    func testLiftEndsAnActiveTourExactlyOnce() {
        var engine = makeEngine()
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: false)
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.45, y: 0.5), onBandList: false)   // .activate
        XCTAssertEqual(engine.feed(fingerCount: 0, centroid: CGPoint(x: 0.45, y: 0.5), onBandList: false), [.end])
        XCTAssertFalse(engine.isActive)
        // A second lift frame is a no-op (no double end).
        XCTAssertEqual(engine.feed(fingerCount: 0, centroid: CGPoint(x: 0.45, y: 0.5), onBandList: false), [])
    }

    func testLiftBeforeActivationDoesNotEnd() {
        var engine = makeEngine()
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: false)   // not enough travel
        XCTAssertEqual(engine.feed(fingerCount: 0, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: false), [],
                       "lifting before the launcher ever opened emits nothing")
    }

    // MARK: - Live tunables

    func testUpdateDistancesRetargetsFutureStepsWithoutPhantom() {
        var engine = makeEngine()
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.30, y: 0.5), onBandList: false)
        _ = engine.feed(fingerCount: 4, centroid: CGPoint(x: 0.40, y: 0.5), onBandList: false)   // .activate
        _ = engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.40, y: 0.5), onBandList: false)   // re-baseline
        // Coarsen the item step mid-tour; 0.10 of travel now yields one step (0.08) instead of the two an
        // 0.04 step would have. Off the exact boundary so the assertion isn't FP-fragile.
        engine.updateDistances(activationThreshold: 0.05, itemStep: 0.08, bandStep: 0.09)
        XCTAssertEqual(engine.feed(fingerCount: 2, centroid: CGPoint(x: 0.50, y: 0.5), onBandList: false),
                       [.stepHorizontal(1)], "the coarser step distance is honoured immediately, no phantom")
    }
}
