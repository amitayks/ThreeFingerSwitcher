import XCTest
import CoreGraphics
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
        guard case let .action(action, adjustment, _) = item.kind else {
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

    // MARK: - Screenshot clipboard destination

    func testSupportsClipboardDestination() {
        for a in [SystemAction.screenshotSelection, .screenshotFullScreen] {
            XCTAssertTrue(a.supportsClipboardDestination)
        }
        // Tools owns its own destination menu; non-screenshot actions never support it.
        for a in [SystemAction.screenshotTools, .volumeUp, .missionControl, .closeFrontWindow] {
            XCTAssertFalse(a.supportsClipboardDestination)
        }
    }

    func testScreenshotClipboardItemRoundTrips() throws {
        let item = LaunchItem(title: "Shot", icon: .sfSymbol("camera.viewfinder"),
                              kind: .action(.screenshotSelection, nil, screenshotToClipboard: true))
        let back = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(item, back)
        guard case let .action(_, _, toClipboard) = back.kind else { return XCTFail("expected .action kind") }
        XCTAssertEqual(toClipboard, true)
    }

    /// A screenshot action saved BEFORE this feature has no third associated value in its `.action`
    /// encoding. It must still decode (with the option off), or loading would throw and wipe favorites.
    func testLegacyScreenshotActionDecodesWithoutClipboardFlag() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000002","title":"Shot",\
        "icon":{"sfSymbol":{"_0":"camera.viewfinder"}},\
        "kind":{"action":{"_0":"screenshotSelection"}}}
        """
        let item = try JSONDecoder().decode(LaunchItem.self, from: Data(json.utf8))
        guard case let .action(action, adjustment, toClipboard) = item.kind else {
            return XCTFail("expected .action kind")
        }
        XCTAssertEqual(action, .screenshotSelection)
        XCTAssertNil(adjustment)
        XCTAssertNil(toClipboard)   // absent third value decodes to nil (≡ off)
    }

    // MARK: - screenshotShortcut (pure)

    func testScreenshotShortcutAddsControlOnlyWhenToClipboard() {
        // Selection: ⇧⌘4 (file) vs ⌃⇧⌘4 (clipboard).
        XCTAssertEqual(LaunchService.screenshotShortcut(for: .screenshotSelection, toClipboard: false).keyCode, 0x15)
        XCTAssertFalse(LaunchService.screenshotShortcut(for: .screenshotSelection, toClipboard: false).flags.contains(.maskControl))
        XCTAssertTrue(LaunchService.screenshotShortcut(for: .screenshotSelection, toClipboard: true).flags.contains(.maskControl))

        // Full Screen: ⇧⌘3 (file) vs ⌃⇧⌘3 (clipboard).
        XCTAssertEqual(LaunchService.screenshotShortcut(for: .screenshotFullScreen, toClipboard: false).keyCode, 0x14)
        XCTAssertFalse(LaunchService.screenshotShortcut(for: .screenshotFullScreen, toClipboard: false).flags.contains(.maskControl))
        XCTAssertTrue(LaunchService.screenshotShortcut(for: .screenshotFullScreen, toClipboard: true).flags.contains(.maskControl))

        // Both always carry the ⇧⌘ base.
        for action in [SystemAction.screenshotSelection, .screenshotFullScreen] {
            for toClip in [true, false] {
                let flags = LaunchService.screenshotShortcut(for: action, toClipboard: toClip).flags
                XCTAssertTrue(flags.contains(.maskShift) && flags.contains(.maskCommand))
            }
        }
    }

    func testScreenshotToolsNeverAddsControl() {
        // Tools (⇧⌘5) has no modifier route to the clipboard; the flag is inert for it.
        for toClip in [true, false] {
            let shot = LaunchService.screenshotShortcut(for: .screenshotTools, toClipboard: toClip)
            XCTAssertEqual(shot.keyCode, 0x17)
            XCTAssertFalse(shot.flags.contains(.maskControl))
            XCTAssertTrue(shot.flags.contains(.maskShift) && shot.flags.contains(.maskCommand))
        }
    }
}
