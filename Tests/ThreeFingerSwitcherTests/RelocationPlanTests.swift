import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for `RelocationPlan` (NativeGesture/RelocationPlan.swift): the pure compilation of a
/// gesture-feature set into final trackpad-key values, including the shared four-finger key
/// resolutions that the historic per-feature mutators got wrong (the launcher needs `4F-horiz=2`
/// where the horizontal relocation alone parks `1`; the launcher needs `4F-vert=0` where the
/// Space-row relocation alone parks `2`).
final class RelocationPlanTests: XCTestCase {
    private let h3 = TrackpadKey.threeFingerHoriz
    private let v3 = TrackpadKey.threeFingerVert
    private let h4 = TrackpadKey.fourFingerHoriz
    private let v4 = TrackpadKey.fourFingerVert

    // MARK: - Single features

    func testEmptySetTouchesNothing() {
        XCTAssertTrue(RelocationPlan.assignments(for: []).isEmpty)
    }

    func testHorizontalOnly() {
        let plan = RelocationPlan.assignments(for: .horizontal)
        XCTAssertEqual(plan, [h3: 2, h4: 1])   // free 3F horiz, park full-screen swipe on 4F
    }

    func testSpaceRowsOnly() {
        let plan = RelocationPlan.assignments(for: .spaceRows)
        XCTAssertEqual(plan, [v3: 0, v4: 2])   // free 3F vert, park Mission Control on 4F
    }

    func testLauncherOnly() {
        let plan = RelocationPlan.assignments(for: .launcher)
        XCTAssertEqual(plan, [h4: 2, v4: 0])   // free both 4F swipes
    }

    // MARK: - Combinations (the shared-key resolutions)

    func testHorizontalPlusLauncherFreesFourFingerHorizontal() {
        let plan = RelocationPlan.assignments(for: [.horizontal, .launcher])
        XCTAssertEqual(plan[h3], 2)
        XCTAssertEqual(plan[h4], 2, "launcher must win the shared 4F-horiz key (freed, not parked)")
        XCTAssertEqual(plan[v4], 0)
        XCTAssertNil(plan[v3], "3F vertical is untouched without the Space-rows feature")
    }

    func testSpaceRowsPlusLauncherFreesFourFingerVertical() {
        let plan = RelocationPlan.assignments(for: [.spaceRows, .launcher])
        XCTAssertEqual(plan[v3], 0)
        XCTAssertEqual(plan[v4], 0, "launcher must win the shared 4F-vert key (freed, not parked)")
        XCTAssertEqual(plan[h4], 2)
        XCTAssertNil(plan[h3], "3F horizontal is untouched without the horizontal feature")
    }

    func testHorizontalPlusSpaceRows() {
        let plan = RelocationPlan.assignments(for: [.horizontal, .spaceRows])
        XCTAssertEqual(plan, [h3: 2, h4: 1, v3: 0, v4: 2])
    }

    func testAllThree() {
        let plan = RelocationPlan.assignments(for: .all)
        XCTAssertEqual(plan, [h3: 2, v3: 0, h4: 2, v4: 0],
                       "the all-on end state: both 3F lanes freed, both 4F swipes freed (MC via app synthesis)")
    }

    // MARK: - Backup scopes

    func testTouchedKeysPerFeature() {
        XCTAssertEqual(RelocationPlan.touchedKeys(for: .horizontal), [h3, h4])
        XCTAssertEqual(RelocationPlan.touchedKeys(for: .spaceRows), [v3, v4])
        XCTAssertEqual(RelocationPlan.touchedKeys(for: .launcher), [h4, v4])
    }

    func testBackupSlotsMatchTheHistoricPerFeatureSlots() {
        XCTAssertEqual(RelocationPlan.backupSlot(for: .horizontal), "trackpadGestureBackup")
        XCTAssertEqual(RelocationPlan.backupSlot(for: .spaceRows), "verticalGestureBackup")
        XCTAssertEqual(RelocationPlan.backupSlot(for: .launcher), "fourFingerGestureBackup")
    }

    // MARK: - Backup tokens

    func testBackupTokenAbsentAndValues() {
        XCTAssertEqual(RelocationBackup.token(forRawValue: nil), "absent")
        XCTAssertEqual(RelocationBackup.token(forRawValue: "  "), "absent")
        XCTAssertEqual(RelocationBackup.token(forRawValue: "junk"), "absent")
        XCTAssertEqual(RelocationBackup.token(forRawValue: "2\n"), "2")
        XCTAssertEqual(RelocationBackup.token(forRawValue: "0"), "0")
    }

    // MARK: - Horizontal config statics (the absent-aware upgrade)

    func testHorizStateMapping() {
        XCTAssertEqual(TrackpadGestureConfig.horizState(forRawValue: "1"), .claimedByThreeFinger)
        XCTAssertEqual(TrackpadGestureConfig.horizState(forRawValue: "2"), .free)
        XCTAssertEqual(TrackpadGestureConfig.horizState(forRawValue: nil), .unknown)
        XCTAssertEqual(TrackpadGestureConfig.horizState(forRawValue: "x"), .unknown)
    }

    func testHorizontalRestoreActionIsAbsentAware() {
        XCTAssertEqual(TrackpadGestureConfig.restoreAction(forToken: "absent"), .delete)
        XCTAssertEqual(TrackpadGestureConfig.restoreAction(forToken: "1"), .write(1))
        XCTAssertEqual(TrackpadGestureConfig.restoreAction(forToken: nil), .none)
        XCTAssertEqual(TrackpadGestureConfig.restoreAction(forToken: "junk"), .none)
    }
}
