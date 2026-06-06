import XCTest
@testable import ThreeFingerSwitcherCore

/// The scroll tap's consume decision is a pure helper so it can be asserted without standing up a
/// `CGEventTap`. The launcher-open clause is what lets two-finger navigation be captured; with the
/// launcher closed the rule must fall back to `≥3` fingers so normal two-finger scrolling passes.
@MainActor
final class ScrollConsumeRuleTests: XCTestCase {

    func test_consumes_atTwoFingers_whenLauncherOpen() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: true))
    }

    func test_passesThrough_atTwoFingers_whenLauncherClosed() {
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 2, launcherOpen: false))
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 1, launcherOpen: false))
        XCTAssertFalse(AppCoordinator.shouldConsumeScroll(fingerCount: 0, launcherOpen: false))
    }

    func test_consumes_atThreeOrMore_regardlessOfLauncher() {
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 3, launcherOpen: false))
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 4, launcherOpen: false))
        XCTAssertTrue(AppCoordinator.shouldConsumeScroll(fingerCount: 3, launcherOpen: true))
    }
}
