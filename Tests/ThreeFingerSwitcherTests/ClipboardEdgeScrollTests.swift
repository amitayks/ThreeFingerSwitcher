import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests the eased held-in-zone auto-repeat cadence (change `positional-navigation`, D4) that replaced
/// the old tick-indexed edge ramp: the interval shrinks the longer an offset is held, eases smoothly
/// (no abrupt slow→fast jump), and floors out. The overflow gate was removed — auto-repeat applies to
/// all launcher navigation and a step simply clamps (and skips the dwell reset) when there's nowhere to go.
final class ClipboardEdgeScrollTests: XCTestCase {

    private let initialDelay = 0.22, floor = 0.03, ramp = 1.2

    private func interval(_ dwell: Double) -> Double {
        RepeatCadence.interval(dwellElapsed: dwell, initialDelay: initialDelay, floor: floor, rampTime: ramp)
    }

    // MARK: Eased acceleration over dwell

    func testIntervalAcceleratesWithDwell() {
        let first = interval(0)
        let later = interval(0.4)
        let muchLater = interval(1.0)
        XCTAssertGreaterThan(first, later, "the list speeds up the longer the offset is held")
        XCTAssertGreaterThan(later, muchLater)
    }

    func testFirstIntervalIsTheInitialDelay() {
        // The first scheduled tick (dwell = 0) is the comfortable initial delay — the immediate first
        // step already fired from the recognizer's outer-threshold crossing, so we don't jump to the floor.
        XCTAssertEqual(interval(0), initialDelay, accuracy: 1e-9)
        XCTAssertGreaterThan(interval(0.05), floor, "does not snap straight to the fastest rate")
    }

    func testIntervalIsFloored() {
        XCTAssertEqual(interval(ramp), floor, accuracy: 1e-9, "reaches the floor at the ramp time")
        XCTAssertEqual(interval(10_000), floor, accuracy: 1e-9, "never drops below the floor")
    }
}
