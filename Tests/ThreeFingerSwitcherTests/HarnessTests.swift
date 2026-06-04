import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

final class HarnessTests: XCTestCase {
    /// Trivial placeholder: verifies the test target builds and runs against the Core library.
    func testHarnessRuns() {
        XCTAssertEqual(2 + 2, 4)
    }

    /// Smoke test for the AppSettings injection seam (isolated UserDefaults).
    @MainActor
    func testAppSettingsInjectedDefaults() {
        let defaults = UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.stepDistance = 0.1
        XCTAssertEqual(settings.stepDistance, 0.1, accuracy: 1e-9)
    }

    /// Smoke test for the TouchFrame test initializer.
    func testTouchFrameTestInit() {
        let frame = TouchFrame(testFingerCount: 3, centroid: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(frame.fingerCount, 3)
        XCTAssertEqual(frame.centroid.x, 0.5, accuracy: 1e-9)
    }

    /// Smoke test for the extracted Space-grouping logic.
    func testSpaceGroupingPutsCurrentSpaceFirst() {
        let other = WindowInfo(
            id: 1, pid: 1, appName: "A", title: "", appIcon: nil,
            frame: .zero, axElement: nil, isOnCurrentSpace: false, spaceID: 9
        )
        let current = WindowInfo(
            id: 2, pid: 2, appName: "B", title: "", appIcon: nil,
            frame: .zero, axElement: nil, isOnCurrentSpace: true, spaceID: 3
        )
        let grouped = SpaceGrouping.group([other, current])
        XCTAssertEqual(grouped.rows.count, 2)
        XCTAssertEqual(grouped.startRow, 0)
        XCTAssertTrue(grouped.rows[0].first?.isOnCurrentSpace ?? false)
        XCTAssertEqual(grouped.labels, ["1", "2"])
    }
}
