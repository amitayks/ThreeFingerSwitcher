import XCTest
import AppKit
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for `SwitcherModel` (Sources/ThreeFingerSwitcher/Overlay/SwitcherModel.swift).
/// The grid (`rows`, `currentRow`, `selectedColumn`/`selectedIndex`) is the source of truth and
/// `windows`/`selectedIndex` are derived/published. These tests pin the clamping, row-direction,
/// and derivation behavior.
@MainActor
final class SwitcherModelTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a `WindowInfo` per the scaffold snippet. Only `id` (and trivial labels) vary.
    private func makeWindow(
        id: CGWindowID,
        onCurrentSpace: Bool = true,
        spaceID: CGSSpaceID? = nil
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid_t(id),
            appName: "App\(id)",
            title: "",
            appIcon: nil,
            frame: .zero,
            axElement: nil,
            isOnCurrentSpace: onCurrentSpace,
            spaceID: spaceID,
            spaceIndex: 0
        )
    }

    /// A 3-row grid: row0 has ids [10,11], row1 has ids [20,21,22], row2 has ids [30].
    private func threeRowGrid() -> [[WindowInfo]] {
        [
            [makeWindow(id: 10), makeWindow(id: 11)],
            [makeWindow(id: 20), makeWindow(id: 21), makeWindow(id: 22)],
            [makeWindow(id: 30)],
        ]
    }

    // MARK: - Initial state

    func testInitialStateIsEmpty() {
        // Arrange / Act
        let model = SwitcherModel()

        // Assert
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.rowLabels.isEmpty)
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertEqual(model.lastRowDirection, 1)
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertTrue(model.thumbnails.isEmpty)
        XCTAssertFalse(model.overflow)
        XCTAssertEqual(model.rowCount, 0)
        XCTAssertNil(model.selectedWindow)
        XCTAssertTrue(model.currentRowIDs.isEmpty)
    }

    // MARK: - setRows

    func testSetRowsBuildsGridAndStartsOnStartRow() {
        // Arrange
        let model = SwitcherModel()
        let grid = threeRowGrid()

        // Act: start on row 1.
        model.setRows(grid, labels: ["1", "2", "3"], startRow: 1, column: 0)

        // Assert
        XCTAssertEqual(model.rowCount, 3)
        XCTAssertEqual(model.rowLabels, ["1", "2", "3"])
        XCTAssertEqual(model.currentRow, 1)
        // Derived windows == rows[currentRow].
        XCTAssertEqual(model.windows.map(\.id), [20, 21, 22])
    }

    func testSetRowsDerivesWindowsFromCurrentRowAndClampsSelectedIndex() {
        // Arrange
        let model = SwitcherModel()
        let grid = threeRowGrid()

        // Act: ask for column 99 on row 1 (which has 3 windows) -> clamp to last index 2.
        model.setRows(grid, labels: ["1", "2", "3"], startRow: 1, column: 99)

        // Assert
        XCTAssertEqual(model.windows.map(\.id), [20, 21, 22])
        XCTAssertEqual(model.selectedIndex, 2)
        XCTAssertEqual(model.selectedWindow?.id, 22)
    }

    func testSetRowsHonorsRequestedColumnWhenInRange() {
        // Arrange
        let model = SwitcherModel()
        let grid = threeRowGrid()

        // Act
        model.setRows(grid, labels: ["1", "2", "3"], startRow: 1, column: 1)

        // Assert
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(model.selectedWindow?.id, 21)
    }

    func testSetRowsClampsStartRowAboveRange() {
        // Arrange
        let model = SwitcherModel()
        let grid = threeRowGrid()

        // Act: startRow far past the end -> clamp to last row index (2).
        model.setRows(grid, labels: ["1", "2", "3"], startRow: 10, column: 0)

        // Assert
        XCTAssertEqual(model.currentRow, 2)
        XCTAssertEqual(model.windows.map(\.id), [30])
    }

    func testSetRowsClampsNegativeStartRow() {
        // Arrange
        let model = SwitcherModel()
        let grid = threeRowGrid()

        // Act
        model.setRows(grid, labels: ["1", "2", "3"], startRow: -5, column: 0)

        // Assert
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertEqual(model.windows.map(\.id), [10, 11])
    }

    func testSetRowsWithEmptyGridClampsCurrentRowToZeroAndEmptiesWindows() {
        // Arrange
        let model = SwitcherModel()

        // Act: empty rows, startRow nonzero -> currentRow clamps to 0, windows empty.
        model.setRows([], labels: [], startRow: 3, column: 4)

        // Assert
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.selectedWindow)
    }

    func testSetRowsResetsThumbnails() {
        // Arrange
        let model = SwitcherModel()
        model.setThumbnail(NSImage(), for: 10)
        XCTAssertFalse(model.thumbnails.isEmpty)

        // Act
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 0, column: 0)

        // Assert: setRows clears the thumbnail cache.
        XCTAssertTrue(model.thumbnails.isEmpty)
    }

    // MARK: - setColumn

    func testSetColumnClampsAboveRange() {
        // Arrange
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 0)

        // Act: row 1 has 3 windows (indices 0...2); request 5 -> clamp to 2.
        model.setColumn(5)

        // Assert
        XCTAssertEqual(model.selectedIndex, 2)
        XCTAssertEqual(model.selectedWindow?.id, 22)
    }

    func testSetColumnClampsBelowRange() {
        // Arrange
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 2)

        // Act: negative -> clamp to 0.
        model.setColumn(-3)

        // Assert
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selectedWindow?.id, 20)
    }

    func testSetColumnHonorsInRangeValue() {
        // Arrange
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 0)

        // Act
        model.setColumn(1)

        // Assert
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(model.selectedWindow?.id, 21)
    }

    func testSetColumnAtUpperBoundary() {
        // Arrange: row 1 has 3 windows -> last valid index is 2.
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 0)

        // Act
        model.setColumn(2)

        // Assert
        XCTAssertEqual(model.selectedIndex, 2)
    }

    func testSetColumnOnEmptyWindowsStaysZero() {
        // Arrange: empty grid -> windows empty, clamp hi == max(count-1, 0) == 0.
        let model = SwitcherModel()
        model.setRows([], labels: [], startRow: 0, column: 0)

        // Act
        model.setColumn(7)

        // Assert
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.selectedWindow)
    }

    // MARK: - setRow

    func testSetRowToLaterRowSetsDirectionPlusOneAndResetsColumn() {
        // Arrange: start on row 0, select a non-zero column.
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 0, column: 1)
        XCTAssertEqual(model.selectedIndex, 1)

        // Act: move to a later row.
        model.setRow(1)

        // Assert
        XCTAssertEqual(model.currentRow, 1)
        XCTAssertEqual(model.lastRowDirection, 1)
        XCTAssertEqual(model.selectedIndex, 0)         // column reset to 0
        XCTAssertEqual(model.windows.map(\.id), [20, 21, 22])
    }

    func testSetRowToEarlierRowSetsDirectionMinusOne() {
        // Arrange: start on row 2.
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 2, column: 0)

        // Act: move to an earlier row.
        model.setRow(0)

        // Assert
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertEqual(model.lastRowDirection, -1)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.windows.map(\.id), [10, 11])
    }

    func testSetRowToSameRowLeavesDirectionUnchanged() {
        // Arrange: move forward once so direction is a known +1, then a backward move to set -1.
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 0)
        model.setRow(0)                                 // direction becomes -1
        XCTAssertEqual(model.lastRowDirection, -1)

        // Act: set the row to the current row (no change).
        model.setRow(0)

        // Assert: direction is untouched because target == currentRow.
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertEqual(model.lastRowDirection, -1)
    }

    func testSetRowResetsSelectedColumnToZeroEvenWhenStayingOnSameRow() {
        // Arrange: select a non-zero column on the current row.
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 2)
        XCTAssertEqual(model.selectedIndex, 2)

        // Act: setRow to the same row still re-applies the row with column 0.
        model.setRow(1)

        // Assert
        XCTAssertEqual(model.currentRow, 1)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testSetRowClampsAboveRange() {
        // Arrange
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 0, column: 0)

        // Act: past the end -> clamp to last index 2 (a later row -> +1).
        model.setRow(99)

        // Assert
        XCTAssertEqual(model.currentRow, 2)
        XCTAssertEqual(model.lastRowDirection, 1)
        XCTAssertEqual(model.windows.map(\.id), [30])
    }

    func testSetRowClampsBelowRange() {
        // Arrange: start on row 2.
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 2, column: 0)

        // Act: negative -> clamp to 0 (earlier row -> -1).
        model.setRow(-10)

        // Assert
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertEqual(model.lastRowDirection, -1)
        XCTAssertEqual(model.windows.map(\.id), [10, 11])
    }

    func testSetRowOnEmptyGridIsNoOp() {
        // Arrange: empty grid; capture default state.
        let model = SwitcherModel()
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertEqual(model.lastRowDirection, 1)

        // Act: setRow guards against empty rows and returns early.
        model.setRow(5)

        // Assert: nothing changed (no crash, direction untouched).
        XCTAssertEqual(model.currentRow, 0)
        XCTAssertEqual(model.lastRowDirection, 1)
        XCTAssertTrue(model.windows.isEmpty)
    }

    // MARK: - currentRowIDs

    func testCurrentRowIDsMapsCurrentRow() {
        // Arrange
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 0)

        // Act / Assert: ids of the current (row 1) windows.
        XCTAssertEqual(model.currentRowIDs, [20, 21, 22])

        // Act: switch rows -> ids follow.
        model.setRow(2)
        XCTAssertEqual(model.currentRowIDs, [30])
    }

    func testCurrentRowIDsEmptyWhenNoWindows() {
        // Arrange
        let model = SwitcherModel()
        model.setRows([], labels: [], startRow: 0, column: 0)

        // Act / Assert
        XCTAssertTrue(model.currentRowIDs.isEmpty)
    }

    // MARK: - selectedWindow

    func testSelectedWindowReturnsElementAtSelectedIndex() {
        // Arrange
        let model = SwitcherModel()
        model.setRows(threeRowGrid(), labels: ["1", "2", "3"], startRow: 1, column: 0)

        // Act
        model.setColumn(2)

        // Assert
        XCTAssertEqual(model.selectedWindow?.id, 22)
    }

    func testSelectedWindowIsNilWhenWindowsEmpty() {
        // Arrange
        let model = SwitcherModel()
        model.setRows([], labels: [], startRow: 0, column: 0)

        // Act / Assert
        XCTAssertNil(model.selectedWindow)
    }

    // MARK: - setThumbnail

    func testSetThumbnailStoresByID() {
        // Arrange
        let model = SwitcherModel()
        let image = NSImage()

        // Act
        model.setThumbnail(image, for: 42)

        // Assert
        XCTAssertTrue(model.thumbnails[42] === image)
    }

    func testSetThumbnailOverwritesExistingID() {
        // Arrange
        let model = SwitcherModel()
        let first = NSImage()
        let second = NSImage()
        model.setThumbnail(first, for: 7)

        // Act
        model.setThumbnail(second, for: 7)

        // Assert: same id now maps to the new image.
        XCTAssertTrue(model.thumbnails[7] === second)
        XCTAssertEqual(model.thumbnails.count, 1)
    }

    func testSetThumbnailKeepsDistinctIDsSeparate() {
        // Arrange
        let model = SwitcherModel()
        let imageA = NSImage()
        let imageB = NSImage()

        // Act
        model.setThumbnail(imageA, for: 1)
        model.setThumbnail(imageB, for: 2)

        // Assert
        XCTAssertTrue(model.thumbnails[1] === imageA)
        XCTAssertTrue(model.thumbnails[2] === imageB)
        XCTAssertEqual(model.thumbnails.count, 2)
    }
}
