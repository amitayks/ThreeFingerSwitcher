import XCTest
@testable import ThreeFingerSwitcherCore

/// The scroll tap's consume decision is a pure helper so it can be asserted without standing up a
/// `CGEventTap`. The overlay-open clauses are what let two-finger navigation be captured; with both
/// overlays closed the rule must fall back to `≥3` fingers so normal two-finger scrolling passes.
@MainActor
final class ScrollConsumeRuleTests: XCTestCase {

    func test_consumes_atTwoFingers_whenLauncherOpen() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: true, switcherOpen: false))
    }

    func test_consumes_atTwoFingers_whenSwitcherOpen() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: false, switcherOpen: true))
    }

    func test_passesThrough_atTwoFingers_whenBothOverlaysClosed() {
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: false, switcherOpen: false))
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 1, launcherOpen: false, switcherOpen: false))
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 0, launcherOpen: false, switcherOpen: false))
    }

    func test_consumes_atThreeOrMore_regardlessOfOverlays() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 3, launcherOpen: false, switcherOpen: false))
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 4, launcherOpen: false, switcherOpen: false))
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 3, launcherOpen: true, switcherOpen: true))
    }
}
