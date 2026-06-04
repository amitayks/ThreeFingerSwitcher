import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for the extracted `SpaceGrouping.group` symbol.
///
/// Behavior under test (from Sources/.../Windows/SpaceGrouping.swift):
///   - Windows bucket by `spaceID ?? 0`.
///   - A bucket is "current" if ANY of its windows has `isOnCurrentSpace == true`.
///   - Sorted output: current bucket(s) first, remaining buckets by ascending spaceID.
///   - `labels` are 1-based row numbers as strings ("1", "2", ...).
///   - `startRow` is the index of the first current-Space row, or 0 if none.
///   - In-Space (within-bucket) order matches the snapshot input order.
///   - Empty Spaces never appear (only spaceIDs present in the input get rows).
final class SpaceGroupingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a WindowInfo varying only the fields that affect grouping
    /// (id for identity assertions, isOnCurrentSpace, and spaceID).
    private func makeWindow(
        id: CGWindowID,
        appName: String = "App",
        isOnCurrentSpace: Bool,
        spaceID: CGSSpaceID?
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
            spaceID: spaceID
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
        // Arrange: three windows all on the same (current) Space.
        let w1 = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: 5)
        let w2 = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: 5)
        let w3 = makeWindow(id: 3, isOnCurrentSpace: true, spaceID: 5)

        // Act
        let result = SpaceGrouping.group([w1, w2, w3])

        // Assert
        XCTAssertEqual(result.rows.count, 1, "A single Space yields exactly one row")
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2, 3], "All windows land in the single row, in order")
        XCTAssertEqual(result.labels, ["1"], "Single row gets the 1-based label \"1\"")
        XCTAssertEqual(result.startRow, 0, "The only (current) row is at index 0")
    }

    func testSingleNonCurrentSpaceStillProducesRowWithStartRowZero() {
        // Arrange: one Space, none of whose windows are on the current Space.
        let w1 = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 7)
        let w2 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 7)

        // Act
        let result = SpaceGrouping.group([w1, w2])

        // Assert
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2])
        XCTAssertEqual(result.labels, ["1"])
        XCTAssertEqual(result.startRow, 0, "With no current Space, startRow falls back to 0")
    }

    // MARK: - Current Space placement

    func testCurrentSpaceBucketIsRowZeroAndStartRowPointsAtIt() {
        // Arrange: an off-Space window enumerated before the current-Space window.
        let other = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 9)
        let current = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: 3)

        // Act
        let result = SpaceGrouping.group([other, current])

        // Assert
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.startRow, 0, "Current-Space row is row 0")
        XCTAssertTrue(result.rows[0].allSatisfy { $0.isOnCurrentSpace },
                      "Row 0 is the current-Space bucket")
        XCTAssertEqual(result.rows[0].map(\.id), [2], "Current Space (id 3) comes first")
        XCTAssertEqual(result.rows[1].map(\.id), [1], "Off-Space (id 9) follows")
        XCTAssertEqual(result.labels, ["1", "2"])
    }

    func testCurrentSpaceComesFirstEvenWhenItHasTheLargestSpaceID() {
        // Arrange: current Space has the numerically largest id; it must still lead.
        let a = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 2)
        let b = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 4)
        let current = makeWindow(id: 3, isOnCurrentSpace: true, spaceID: 100)

        // Act
        let result = SpaceGrouping.group([a, b, current])

        // Assert
        XCTAssertEqual(result.startRow, 0)
        XCTAssertEqual(result.rows[0].map(\.id), [3], "Current Space (id 100) leads despite being largest")
        // Off-Space rows ordered by ascending spaceID: 2 then 4.
        XCTAssertEqual(result.rows[1].map(\.id), [1])
        XCTAssertEqual(result.rows[2].map(\.id), [2])
    }

    /// A bucket is "current" if ANY of its windows is on the current Space, even if it
    /// was first introduced into the bucket by a window that was NOT current.
    func testBucketBecomesCurrentIfAnyWindowIsOnCurrentSpace() {
        // Arrange: spaceID 5 introduced by a non-current window, then a current one.
        let nonCurrentInSameSpace = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 5)
        let currentInSameSpace = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: 5)
        let otherSpace = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 1)

        // Act
        let result = SpaceGrouping.group([nonCurrentInSameSpace, currentInSameSpace, otherSpace])

        // Assert
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.startRow, 0)
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2],
                       "Space 5 is the current row (any-current rule) and keeps in-Space order")
        XCTAssertEqual(result.rows[1].map(\.id), [3], "Space 1 is the lone off-Space row")
    }

    // MARK: - Off-Space ordering

    func testOffSpaceRowsOrderedByAscendingSpaceID() {
        // Arrange: current Space plus three off-Spaces, fed out of id order.
        let current = makeWindow(id: 10, isOnCurrentSpace: true, spaceID: 50)
        let s30 = makeWindow(id: 30, isOnCurrentSpace: false, spaceID: 30)
        let s8 = makeWindow(id: 8, isOnCurrentSpace: false, spaceID: 8)
        let s20 = makeWindow(id: 20, isOnCurrentSpace: false, spaceID: 20)

        // Act
        let result = SpaceGrouping.group([current, s30, s8, s20])

        // Assert
        XCTAssertEqual(result.rows.count, 4)
        XCTAssertEqual(result.startRow, 0)
        XCTAssertEqual(result.rows[0].map(\.id), [10], "Current row first")
        XCTAssertEqual(result.rows.dropFirst().map { $0.first!.spaceID },
                       [8, 20, 30],
                       "Off-Space rows sorted by ascending spaceID")
        XCTAssertEqual(result.labels, ["1", "2", "3", "4"])
    }

    func testAllOffSpaceOrderedByAscendingSpaceIDWithStartRowZero() {
        // Arrange: no current Space at all; everything sorts by ascending spaceID.
        let s9 = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: 9)
        let s3 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 3)
        let s6 = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 6)

        // Act
        let result = SpaceGrouping.group([s9, s3, s6])

        // Assert
        XCTAssertEqual(result.rows.map { $0.first!.spaceID }, [3, 6, 9])
        XCTAssertEqual(result.startRow, 0, "No current Space => startRow 0")
        XCTAssertEqual(result.labels, ["1", "2", "3"])
    }

    // MARK: - In-Space order preservation

    func testInSpaceOrderPreservedWithinEachBucket() {
        // Arrange: interleave windows from two Spaces in the input.
        let cur1 = makeWindow(id: 101, isOnCurrentSpace: true, spaceID: 1)
        let off1 = makeWindow(id: 201, isOnCurrentSpace: false, spaceID: 2)
        let cur2 = makeWindow(id: 102, isOnCurrentSpace: true, spaceID: 1)
        let off2 = makeWindow(id: 202, isOnCurrentSpace: false, spaceID: 2)
        let cur3 = makeWindow(id: 103, isOnCurrentSpace: true, spaceID: 1)

        // Act
        let result = SpaceGrouping.group([cur1, off1, cur2, off2, cur3])

        // Assert: each bucket preserves the relative input order of its members.
        XCTAssertEqual(result.rows[0].map(\.id), [101, 102, 103],
                       "Current Space preserves snapshot order despite interleaving")
        XCTAssertEqual(result.rows[1].map(\.id), [201, 202],
                       "Off-Space preserves snapshot order despite interleaving")
    }

    // MARK: - nil spaceID (legacy current-Space path)

    func testNilSpaceIDsBucketTogetherUnderKeyZero() {
        // Arrange: two nil-spaceID windows (legacy path) collapse into one bucket (key 0).
        let w1 = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: nil)
        let w2 = makeWindow(id: 2, isOnCurrentSpace: true, spaceID: nil)

        // Act
        let result = SpaceGrouping.group([w1, w2])

        // Assert
        XCTAssertEqual(result.rows.count, 1, "nil spaceIDs share the key-0 bucket")
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2])
        XCTAssertEqual(result.startRow, 0)
    }

    func testNilSpaceIDBucketIsDistinctFromSpaceIDZeroBecauseTheyShareKey() {
        // Arrange: a nil-spaceID window and an explicit spaceID 0 window.
        // Both map to key 0 (`spaceID ?? 0`), so they MUST share one bucket.
        let nilSpace = makeWindow(id: 1, isOnCurrentSpace: false, spaceID: nil)
        let zeroSpace = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 0)

        // Act
        let result = SpaceGrouping.group([nilSpace, zeroSpace])

        // Assert
        XCTAssertEqual(result.rows.count, 1,
                       "nil and explicit 0 collapse to the same key-0 bucket")
        XCTAssertEqual(result.rows[0].map(\.id), [1, 2])
    }

    func testNilSpaceIDCurrentBucketLeadsOverNumberedOffSpace() {
        // Arrange: legacy nil-spaceID current window plus an off-Space numbered window.
        let legacyCurrent = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: nil)
        let offSpace = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 4)

        // Act
        let result = SpaceGrouping.group([offSpace, legacyCurrent])

        // Assert
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.startRow, 0)
        XCTAssertEqual(result.rows[0].map(\.id), [1], "key-0 current bucket leads")
        XCTAssertEqual(result.rows[1].map(\.id), [2], "Space 4 off-Space follows")
    }

    // MARK: - Labels

    func testLabelsAreSequential1BasedRowNumbers() {
        // Arrange: one current + three off-Spaces => four rows.
        let current = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: 100)
        let a = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 1)
        let b = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 2)
        let c = makeWindow(id: 4, isOnCurrentSpace: false, spaceID: 3)

        // Act
        let result = SpaceGrouping.group([current, a, b, c])

        // Assert
        XCTAssertEqual(result.labels, ["1", "2", "3", "4"],
                       "Labels are 1-based row indices regardless of spaceID values")
        XCTAssertEqual(result.labels.count, result.rows.count,
                       "One label per row")
    }

    // MARK: - Comprehensive scenario

    func testMixedScenarioFullOrderingAndStartRow() {
        // Arrange: current Space 50 (two windows, interleaved with others),
        // plus off-Spaces 5, 30, 12 fed out of order.
        let cur1 = makeWindow(id: 1, isOnCurrentSpace: true, spaceID: 50)
        let off30 = makeWindow(id: 2, isOnCurrentSpace: false, spaceID: 30)
        let off5a = makeWindow(id: 3, isOnCurrentSpace: false, spaceID: 5)
        let cur2 = makeWindow(id: 4, isOnCurrentSpace: true, spaceID: 50)
        let off12 = makeWindow(id: 5, isOnCurrentSpace: false, spaceID: 12)
        let off5b = makeWindow(id: 6, isOnCurrentSpace: false, spaceID: 5)

        // Act
        let result = SpaceGrouping.group([cur1, off30, off5a, cur2, off12, off5b])

        // Assert
        XCTAssertEqual(result.rows.count, 4, "Spaces 50, 5, 12, 30 => 4 rows")
        XCTAssertEqual(result.startRow, 0)

        // Row 0: current Space 50, in input order.
        XCTAssertEqual(result.rows[0].map(\.id), [1, 4])
        XCTAssertTrue(result.rows[0].allSatisfy { $0.spaceID == 50 })

        // Rows 1..3: off-Spaces by ascending spaceID: 5, 12, 30.
        XCTAssertEqual(result.rows[1].map(\.id), [3, 6], "Space 5, preserving in-Space order")
        XCTAssertEqual(result.rows[2].map(\.id), [5], "Space 12")
        XCTAssertEqual(result.rows[3].map(\.id), [2], "Space 30")

        XCTAssertEqual(result.labels, ["1", "2", "3", "4"])
    }
}
