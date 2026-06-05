import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for the extracted `SpaceGrouping.group` symbol.
///
/// Behavior under test (from Sources/.../Windows/SpaceGrouping.swift):
///   - Windows bucket by `spaceID ?? 0`.
///   - A bucket is "current" if ANY of its windows has `isOnCurrentSpace == true`.
///   - Rows are ordered by `spaceIndex` (Mission Control / display order), NOT current-first
///     and NOT by raw spaceID; ties break on the raw key for determinism.
///   - `startRow` is the index of the current Space's row in that order (its own position,
///     not forced to 0), or 0 if no bucket is current.
///   - `labels` are each row's true 1-based Space number (`spaceIndex + 1`).
///   - In-Space (within-bucket) order matches the snapshot input order.
///   - Empty Spaces never appear (only spaceIDs present in the input get rows).
final class SpaceGroupingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a WindowInfo varying only the fields that affect grouping
    /// (id for identity assertions, isOnCurrentSpace, spaceID, and spaceIndex).
    private func makeWindow(
        id: CGWindowID,
        appName: String = "App",
        isOnCurrentSpace: Bool,
        spaceID: CGSSpaceID?,
        spaceIndex: Int = 0
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid_t(id),
            appName: appName,
            title: "",
            appIcon: nil,
            frame: .zero,
            axElement: nil,
            isOnCurrentSpace: isOnCurrentSpace,
            spaceID: spaceID,
            spaceIndex: spaceIndex
        )
    }

    // MARK: - Empty / single

    func testEmptyInputProducesNoRows() {
        // Arrange
        let windows: [WindowInfo] = []

        // Act
        let result = SpaceGrouping.group(windows)

        // Assert
        XCTAssertTrue(result.rows.isEmpty, "No windows should yield no rows")
        XCTAssertTrue(result.labels.isEmpty, "No windows should yield no labels")
        XCTAssertEqual(result.startRow, 0, "startRow defaults to 0 when there are no rows")
    }

    func testSingleSpaceYieldsOneRow() {
        // Arrange: three windows all on the same (current) Space at index 0.
        let w1 = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: 5, spaceIndex: 0)
        let w2 = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: 5, spaceIndex: 0)
        let w3 = makeWindow(id: 3, isOnCurrentSpace: true, spaceID: 5, spaceIndex: 0)

        // Act
        let result = SpaceGrouping.group([w1, w2, w3])

        // Assert
        XCTAssertEqual(result.rows.count, 1, "A single Space yields exactly one row")
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2, 3], "All windows land in the single row, in order")
        XCTAssertEqual(result.labels, ["1"], "Single row at index 0 gets the true Space number \"1\"")
        XCTAssertEqual(result.startRow, 0, "The only (current) row is at index 0")
    }

    func testSingleNonCurrentSpaceStillProducesRowWithStartRowZero() {
        // Arrange: one off-Space at Mission Control index 2, none current.
        let w1 = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 7, spaceIndex: 2)
        let w2 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 7, spaceIndex: 2)

        // Act
        let result = SpaceGrouping.group([w1, w2])

        // Assert
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2])
        XCTAssertEqual(result.labels, ["3"], "Label is the true Space number (index 2 -> \"3\")")
        XCTAssertEqual(result.startRow, 0, "With no current Space, startRow falls back to 0")
    }

    // MARK: - Mission Control ordering & current-in-place

    func testRowsOrderedByMissionControlIndexNotCurrentFirst() {
        // Arrange: current Space sits at index 1; off-Spaces flank it at 0 and 2.
        let off0 = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 9, spaceIndex: 0)
        let current = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: 3, spaceIndex: 1)
        let off2 = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 5, spaceIndex: 2)

        // Act: fed current-first to prove it is NOT pulled to row 0.
        let result = SpaceGrouping.group([current, off0, off2])

        // Assert
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows.map { $0.map(\.id) }, [[1], [2], [3]],
                       "Rows follow ascending spaceIndex, not current-first")
        XCTAssertEqual(result.startRow, 1, "Current Space is highlighted at its own position (row 1)")
        XCTAssertTrue(result.rows[1].allSatisfy { $0.isOnCurrentSpace }, "Row 1 is the current bucket")
        XCTAssertEqual(result.labels, ["1", "2", "3"])
    }

    func testCurrentSpaceHighlightedInPlaceWhenItHasTheHighestIndex() {
        // Arrange: current Space is the last in Mission Control order.
        let off0 = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 2, spaceIndex: 0)
        let off1 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 4, spaceIndex: 1)
        let current = makeWindow(id: 3, isOnCurrentSpace: true, spaceID: 100, spaceIndex: 2)

        // Act
        let result = SpaceGrouping.group([off0, off1, current])

        // Assert
        XCTAssertEqual(result.rows.map { $0.map(\.id) }, [[1], [2], [3]])
        XCTAssertEqual(result.startRow, 2, "startRow points at the current Space's own (last) position")
        XCTAssertEqual(result.labels, ["1", "2", "3"])
    }

    func testCurrentAtIndexZeroStartsRowZeroNaturally() {
        // Arrange: current Space is the first in Mission Control order.
        let current = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: 50, spaceIndex: 0)
        let off1 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 7, spaceIndex: 1)
        let off2 = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 9, spaceIndex: 2)

        // Act
        let result = SpaceGrouping.group([off2, off1, current])

        // Assert
        XCTAssertEqual(result.rows.map { $0.map(\.id) }, [[1], [2], [3]])
        XCTAssertEqual(result.startRow, 0, "Current Space already at index 0 (not because it was forced)")
    }

    /// A bucket is "current" if ANY of its windows is on the current Space, even if it
    /// was first introduced into the bucket by a window that was NOT current.
    func testBucketBecomesCurrentIfAnyWindowIsOnCurrentSpace() {
        // Arrange: spaceID 5 (index 1) introduced by a non-current window, then a current one.
        let nonCurrentInSameSpace = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 5, spaceIndex: 1)
        let currentInSameSpace = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: 5, spaceIndex: 1)
        let otherSpace = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 1, spaceIndex: 0)

        // Act
        let result = SpaceGrouping.group([nonCurrentInSameSpace, currentInSameSpace, otherSpace])

        // Assert
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].map(\.id), [3], "Index 0 (Space 1) row comes first")
        XCTAssertEqual(result.rows[1].map(\.id), [1, 2],
                       "Space 5 (index 1) is current via the any-current rule and keeps in-Space order")
        XCTAssertEqual(result.startRow, 1, "Current row sits at its own position (row 1)")
    }

    // MARK: - Ordering source: spaceIndex, not raw spaceID

    func testRowsOrderedBySpaceIndexNotRawSpaceID() {
        // Arrange: raw spaceID order disagrees with Mission Control index order.
        //   space 30 -> index 0, space 50 (current) -> index 1, space 8 -> index 2.
        let current = makeWindow(id: 10, isOnCurrentSpace: true, spaceID: 50, spaceIndex: 1)
        let lowIDHighIndex = makeWindow(id: 8, isOnCurrentSpace: false, spaceID: 8, spaceIndex: 2)
        let highIDLowIndex = makeWindow(id: 30, isOnCurrentSpace: false, spaceID: 30, spaceIndex: 0)

        // Act
        let result = SpaceGrouping.group([current, lowIDHighIndex, highIDLowIndex])

        // Assert: ordered by index (30, 50, 8), proving raw spaceID (8 < 30 < 50) is not the key.
        XCTAssertEqual(result.rows.map { $0.first!.spaceID }, [30, 50, 8])
        XCTAssertEqual(result.startRow, 1)
        XCTAssertEqual(result.labels, ["1", "2", "3"])
    }

    func testAllOffSpaceOrderedBySpaceIndexWithStartRowZero() {
        // Arrange: no current Space at all; everything sorts by ascending spaceIndex.
        let idx2 = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 9, spaceIndex: 2)
        let idx0 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 3, spaceIndex: 0)
        let idx1 = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 6, spaceIndex: 1)

        // Act
        let result = SpaceGrouping.group([idx2, idx0, idx1])

        // Assert
        XCTAssertEqual(result.rows.map(\.first!.id), [2, 3, 1], "Ordered by ascending spaceIndex")
        XCTAssertEqual(result.startRow, 0, "No current Space => startRow 0")
        XCTAssertEqual(result.labels, ["1", "2", "3"])
    }

    // MARK: - Labels reflect the true Space number (gaps from omitted empty Spaces)

    func testLabelsReflectTrueSpaceNumberWhenEarlierSpacesAreOmitted() {
        // Arrange: only Spaces at index 2 and 4 have windows (0,1,3 are empty -> omitted).
        let off = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 11, spaceIndex: 2)
        let current = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: 22, spaceIndex: 4)

        // Act
        let result = SpaceGrouping.group([off, current])

        // Assert
        XCTAssertEqual(result.rows.map(\.first!.id), [1, 2])
        XCTAssertEqual(result.labels, ["3", "5"], "Labels are true Space numbers (index+1), not row positions")
        XCTAssertEqual(result.startRow, 1, "Current Space (index 4) is the second listed row")
    }

    // MARK: - In-Space order preservation

    func testInSpaceOrderPreservedWithinEachBucket() {
        // Arrange: interleave windows from two Spaces in the input.
        let cur1 = makeWindow(id: 101, isOnCurrentSpace: true, spaceID: 1, spaceIndex: 0)
        let off1 = makeWindow(id: 201, isOnCurrentSpace: false, spaceID: 2, spaceIndex: 1)
        let cur2 = makeWindow(id: 102, isOnCurrentSpace: true, spaceID: 1, spaceIndex: 0)
        let off2 = makeWindow(id: 202, isOnCurrentSpace: false, spaceID: 2, spaceIndex: 1)
        let cur3 = makeWindow(id: 103, isOnCurrentSpace: true, spaceID: 1, spaceIndex: 0)

        // Act
        let result = SpaceGrouping.group([cur1, off1, cur2, off2, cur3])

        // Assert: each bucket preserves the relative input order of its members.
        XCTAssertEqual(result.rows[0].map(\.id), [101, 102, 103],
                       "Current Space preserves snapshot order despite interleaving")
        XCTAssertEqual(result.rows[1].map(\.id), [201, 202],
                       "Off-Space preserves snapshot order despite interleaving")
        XCTAssertEqual(result.startRow, 0)
    }

    // MARK: - nil spaceID (legacy current-Space path)

    func testNilSpaceIDsBucketTogetherUnderKeyZero() {
        // Arrange: two nil-spaceID windows (legacy path) collapse into one bucket (key 0).
        let w1 = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
        let w2 = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)

        // Act
        let result = SpaceGrouping.group([w1, w2])

        // Assert
        XCTAssertEqual(result.rows.count, 1, "nil spaceIDs share the key-0 bucket")
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2])
        XCTAssertEqual(result.labels, ["1"])
        XCTAssertEqual(result.startRow, 0)
    }

    func testNilSpaceIDBucketIsDistinctFromSpaceIDZeroBecauseTheyShareKey() {
        // Arrange: a nil-spaceID window and an explicit spaceID 0 window.
        // Both map to key 0 (`spaceID ?? 0`), so they MUST share one bucket.
        let nilSpace = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: nil, spaceIndex: 0)
        let zeroSpace = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 0, spaceIndex: 0)

        // Act
        let result = SpaceGrouping.group([nilSpace, zeroSpace])

        // Assert
        XCTAssertEqual(result.rows.count, 1,
                       "nil and explicit 0 collapse to the same key-0 bucket")
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2])
    }

    func testNilSpaceIDCurrentBucketWithNumberedOffSpace() {
        // Arrange: legacy nil-spaceID current window (index 0) plus an off-Space at index 1.
        let legacyCurrent = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
        let offSpace = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 4, spaceIndex: 1)

        // Act
        let result = SpaceGrouping.group([offSpace, legacyCurrent])

        // Assert
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].map(\.id), [1], "key-0 current bucket (index 0) leads")
        XCTAssertEqual(result.rows[1].map(\.id), [2], "Space 4 (index 1) off-Space follows")
        XCTAssertEqual(result.startRow, 0)
        XCTAssertEqual(result.labels, ["1", "2"])
    }

    // MARK: - Comprehensive scenario

    func testMixedScenarioFullOrderingAndStartRow() {
        // Arrange: current Space 50 (index 1, two windows interleaved with others),
        // plus off-Spaces at indices 0 (Space 5, two windows), 2 (Space 12), 3 (Space 30),
        // all fed out of order.
        let cur1 = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: 50, spaceIndex: 1)
        let off30 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 30, spaceIndex: 3)
        let off5a = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 5, spaceIndex: 0)
        let cur2 = makeWindow(id: 4, isOnCurrentSpace: true, spaceID: 50, spaceIndex: 1)
        let off12 = makeWindow(id: 5, isOnCurrentSpace: false, spaceID: 12, spaceIndex: 2)
        let off5b = makeWindow(id: 6, isOnCurrentSpace: false, spaceID: 5, spaceIndex: 0)

        // Act
        let result = SpaceGrouping.group([cur1, off30, off5a, cur2, off12, off5b])

        // Assert
        XCTAssertEqual(result.rows.count, 4, "Spaces 5, 50, 12, 30 => 4 rows")
        XCTAssertEqual(result.startRow, 1, "Current Space 50 sits at its own index (row 1)")

        // Rows ordered by spaceIndex: 0 (Space 5), 1 (Space 50, current), 2 (Space 12), 3 (Space 30).
        XCTAssertEqual(result.rows[0].map(\.id), [3, 6], "Space 5, preserving in-Space order")
        XCTAssertEqual(result.rows[1].map(\.id), [1, 4], "Current Space 50, preserving in-Space order")
        XCTAssertTrue(result.rows[1].allSatisfy { $0.spaceID == 50 })
        XCTAssertEqual(result.rows[2].map(\.id), [5], "Space 12")
        XCTAssertEqual(result.rows[3].map(\.id), [2], "Space 30")

        XCTAssertEqual(result.labels, ["1", "2", "3", "4"])
    }
}
