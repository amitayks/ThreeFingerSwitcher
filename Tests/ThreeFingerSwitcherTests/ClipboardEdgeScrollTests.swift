import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests the pure edge-auto-repeat acceleration ramp (the interval that shrinks the longer an edge is
/// held). The overflow gate was removed — auto-repeat now applies to all launcher navigation and a
/// step simply clamps (and skips the dwell reset) when there's nowhere to go.
final class ClipboardEdgeScrollTests: XCTestCase {

    // MARK: Acceleration ramp

    func testIntervalAcceleratesWithTicks() {
        let first = LauncherOverlayController.edgeInterval(tick: 0, acceleration: 1.0)
        let later = LauncherOverlayController.edgeInterval(tick: 5, acceleration: 1.0)
        let muchLater = LauncherOverlayController.edgeInterval(tick: 20, acceleration: 1.0)
        XCTAssertGreaterThan(first, later, "the list speeds up the longer the edge is held")
        XCTAssertGreaterThan(later, muchLater)
    }

    func testIntervalIsFloored() {
        let veryLate = LauncherOverlayController.edgeInterval(tick: 10_000, acceleration: 3.0)
        XCTAssertGreaterThanOrEqual(veryLate, 0.03, "interval never drops below the floor")
    }

    func testHigherAccelerationIsFaster() {
        let slow = LauncherOverlayController.edgeInterval(tick: 5, acceleration: 0.5)
        let fast = LauncherOverlayController.edgeInterval(tick: 5, acceleration: 3.0)
        XCTAssertGreaterThan(slow, fast, "higher acceleration yields a shorter interval at the same tick")
    }
}
