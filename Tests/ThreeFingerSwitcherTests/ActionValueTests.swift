import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the volume/brightness value control: the pure target-level math, the step-count
/// fallback, Codable round-trip, and — critically — that pre-feature `.action` items still decode
/// (a decode failure would reset the user's favorites to seeded defaults).
final class ActionValueTests: XCTestCase {

    // MARK: - targetLevel (pure)

    func testAbsoluteSetsLevelAndIgnoresDirection() {
        XCTAssertEqual(LaunchService.targetLevel(current: 0.8, up: true,  mode: .absolute, amount: 0.30), 0.30, accuracy: 1e-9)
        XCTAssertEqual(LaunchService.targetLevel(current: 0.1, up: false, mode: .absolute, amount: 0.30), 0.30, accuracy: 1e-9)
    }

    func testAbsoluteClamps() {
        XCTAssertEqual(LaunchService.targetLevel(current: 0.5, up: true, mode: .absolute, amount: 1.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(LaunchService.targetLevel(current: 0.5, up: true, mode: .absolute, amount: -0.2), 0.0, accuracy: 1e-9)
    }

    func testRelativeAddsAndSubtractsByDirection() {
        XCTAssertEqual(LaunchService.targetLevel(current: 0.5, up: true,  mode: .relative, amount: 0.40), 0.9, accuracy: 1e-9)
        XCTAssertEqual(LaunchService.targetLevel(current: 0.5, up: false, mode: .relative, amount: 0.40), 0.1, accuracy: 1e-9)
    }

    func testRelativeClampsAtBounds() {
        XCTAssertEqual(LaunchService.targetLevel(current: 0.8, up: true,  mode: .relative, amount: 0.40), 1.0, accuracy: 1e-9)
        XCTAssertEqual(LaunchService.targetLevel(current: 0.2, up: false, mode: .relative, amount: 0.40), 0.0, accuracy: 1e-9)
    }

    func testStepCountApproximation() {
        XCTAssertEqual(LaunchService.stepCount(forPercent: 6.25), 1)
        XCTAssertEqual(LaunchService.stepCount(forPercent: 40), 6)   // 40 / 6.25 = 6.4 → 6
        XCTAssertEqual(LaunchService.stepCount(forPercent: 1), 1)    // never zero
    }

    // MARK: - Codable

    func testAdjustmentRoundTrips() throws {
        for adj in [ValueAdjustment(mode: .absolute, percent: 30),
                    ValueAdjustment(mode: .relative, percent: 40)] {
            let item = LaunchItem(title: "V", icon: .sfSymbol("speaker.wave.3.fill"),
                                  kind: .action(.volumeUp, adj))
            let back = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(item, back)
        }
    }

    /// A volume action saved BEFORE this feature has no second associated value in its `.action`
    /// encoding. It must still decode (with no adjustment), or loading would throw and wipe favorites.
    func testLegacyActionItemDecodesWithoutAdjustment() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"Vol",\
        "icon":{"sfSymbol":{"_0":"speaker.wave.3.fill"}},\
        "kind":{"action":{"_0":"volumeUp"}}}
        """
        let item = try JSONDecoder().decode(LaunchItem.self, from: Data(json.utf8))
        guard case let .action(action, adjustment) = item.kind else {
            return XCTFail("expected .action kind")
        }
        XCTAssertEqual(action, .volumeUp)
        XCTAssertNil(adjustment)
    }

    func testIsValueAdjustable() {
        for a in [SystemAction.volumeUp, .volumeDown, .brightnessUp, .brightnessDown] {
            XCTAssertTrue(a.isValueAdjustable)
        }
        for a in [SystemAction.mute, .playPause, .missionControl, .closeFrontWindow] {
            XCTAssertFalse(a.isValueAdjustable)
        }
    }
}
