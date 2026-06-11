import XCTest
@testable import ThreeFingerSwitcherCore

/// The scroll tap's consume decision is a pure helper so it can be asserted without standing up a
/// `CGEventTap`. The overlay-open clauses are what let two-finger navigation be captured; with both
/// overlays closed the rule must fall back to `≥3` fingers so normal two-finger scrolling passes.
/// While the AI canvas is active the launcher / switcher clauses relax for 1-2 finger scroll so it
/// reaches the canvas's ScrollView, but `≥3` fingers stays consumed (gesture territory).
@MainActor
final class ScrollConsumeRuleTests: XCTestCase {

    func test_consumes_atTwoFingers_whenLauncherOpen() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: true, switcherOpen: false, canvasActive: false))
    }

    func test_consumes_atTwoFingers_whenSwitcherOpen() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: false, switcherOpen: true, canvasActive: false))
    }

    func test_passesThrough_atTwoFingers_whenBothOverlaysClosed() {
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: false, switcherOpen: false, canvasActive: false))
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 1, launcherOpen: false, switcherOpen: false, canvasActive: false))
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 0, launcherOpen: false, switcherOpen: false, canvasActive: false))
    }

    func test_consumes_atThreeOrMore_regardlessOfOverlays() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 3, launcherOpen: false, switcherOpen: false, canvasActive: false))
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 4, launcherOpen: false, switcherOpen: false, canvasActive: false))
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 3, launcherOpen: true, switcherOpen: true, canvasActive: false))
    }

    // (a) Canvas active + 1-2 finger scroll passes through so it reaches the canvas's ScrollView.
    func test_passesThrough_atTwoFingers_whenCanvasActive() {
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: true, switcherOpen: false, canvasActive: true))
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 1, launcherOpen: true, switcherOpen: false, canvasActive: true))
    }

    // (b) Canvas active still consumes 3+ fingers (a 4-finger resolve swipe must not leak to the front app).
    func test_consumes_atFourFingers_whenCanvasActive() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 4, launcherOpen: true, switcherOpen: false, canvasActive: true))
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 3, launcherOpen: true, switcherOpen: false, canvasActive: true))
    }

    // (c) Normal launcher nav (canvas not active) still consumes 1-2 finger scroll.
    func test_consumes_atTwoFingers_whenLauncherOpen_canvasInactive() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: true, switcherOpen: false, canvasActive: false))
    }

    // (d) Switcher open consumes 1-2 finger scroll (canvas is a launcher-only concept).
    func test_consumes_atTwoFingers_whenSwitcherOpen_explicit() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: false, switcherOpen: true, canvasActive: false))
    }
}
