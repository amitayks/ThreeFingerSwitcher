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
        spaceID: CGSSpaceID? = nil,
        realFrame: CGRect = .zero
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid_t(id),
            appName: "App\(id)",
            title: "",
            appIcon: nil,
            frame: .zero,
            realFrame: realFrame,
            axElement: nil,
            isOnCurrentSpace: onCurrentSpace,
            spaceID: spaceID,
            spaceIndex: 0
        )
    }

    /// A single Space of six square (300x300) windows. With canvas 250x400 the solve packs two cards
    /// per visual row -> grid rows [[0,1],[2,3],[4,5]] (asserted in the navigation tests below).
    private func sixSquareGridModel() -> SwitcherModel {
        let model = SwitcherModel()
        model.setCanvas(CGSize(width: 250, height: 400))
        let square = CGRect(x: 0, y: 0, width: 300, height: 300)
        let windows = (0..<6).map { makeWindow(id: CGWindowID(100 + $0), realFrame: square) }
        model.setRows([windows], labels: ["1"], startRow: 0, column: 0)
        return model
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

    // MARK: - Thumbnail freeze (per Space-switch slide)

    func testFreezeBuffersThumbnailsInsteadOfPublishing() {
        // While frozen (the reel slide is animating), a captured thumbnail must NOT publish — else it
        // re-renders the grid mid-slide and snaps the animation.
        let model = SwitcherModel()
        let image = NSImage()

        model.freezeThumbnails()
        model.setThumbnail(image, for: 42)

        XCTAssertNil(model.thumbnails[42], "a frozen thumbnail is buffered, not published")
    }

    func testFlushAppliesBufferedThumbnails() {
        // Once the slide settles the buffered frames cut in together.
        let model = SwitcherModel()
        let imageA = NSImage()
        let imageB = NSImage()

        model.freezeThumbnails()
        model.setThumbnail(imageA, for: 1)
        model.setThumbnail(imageB, for: 2)
        XCTAssertTrue(model.thumbnails.isEmpty, "nothing published while frozen")

        model.flushThumbnails()
        XCTAssertTrue(model.thumbnails[1] === imageA)
        XCTAssertTrue(model.thumbnails[2] === imageB)
    }

    func testSeedBeforeFreezeStaysPublished() {
        // A cached thumbnail seeded BEFORE the freeze is present for the slide (it slides with the card);
        // only the captures that arrive after the freeze are buffered.
        let model = SwitcherModel()
        let seeded = NSImage()
        let captured = NSImage()

        model.setThumbnail(seeded, for: 1)   // seed (pre-freeze) -> published
        model.freezeThumbnails()
        model.setThumbnail(captured, for: 2) // capture during slide -> buffered

        XCTAssertTrue(model.thumbnails[1] === seeded, "pre-freeze seed stays visible during the slide")
        XCTAssertNil(model.thumbnails[2], "post-freeze capture is held back")

        model.flushThumbnails()
        XCTAssertTrue(model.thumbnails[2] === captured)
    }

    func testFreezeLatestBufferedFrameWinsPerID() {
        // Two captures of the same window during one slide: the later frame is the one that cuts in.
        let model = SwitcherModel()
        let first = NSImage()
        let second = NSImage()

        model.freezeThumbnails()
        model.setThumbnail(first, for: 7)
        model.setThumbnail(second, for: 7)
        model.flushThumbnails()

        XCTAssertTrue(model.thumbnails[7] === second)
    }

    func testFlushIsIdempotentAndUnfreezes() {
        // Flushing with nothing buffered is a no-op, and it clears the frozen flag so later thumbnails
        // publish normally again.
        let model = SwitcherModel()
        model.freezeThumbnails()
        model.flushThumbnails()                 // nothing buffered

        let image = NSImage()
        model.setThumbnail(image, for: 5)       // no longer frozen
        XCTAssertTrue(model.thumbnails[5] === image)
    }

    func testSetRowsClearsFreezeAndBuffer() {
        // A fresh show must never inherit a prior slide's freeze or its buffered frames.
        let model = SwitcherModel()
        model.freezeThumbnails()
        model.setThumbnail(NSImage(), for: 99)  // buffered

        model.setRows([[makeWindow(id: 1)]], labels: ["1"], startRow: 0, column: 0)

        let fresh = NSImage()
        model.setThumbnail(fresh, for: 1)       // should publish (not frozen) and not see id 99
        XCTAssertTrue(model.thumbnails[1] === fresh)
        XCTAssertNil(model.thumbnails[99], "stale buffered frame was dropped on re-show")
    }

    func testSeedThumbnailReplacesOnlyOnDifferentImage() {
        // Re-seeding the SAME cached frame (e.g. the current row, already seeded for all rows on open)
        // is a no-op so it doesn't needlessly republish/re-render; a different frame still replaces.
        let model = SwitcherModel()
        let a = NSImage()
        let b = NSImage()

        model.seedThumbnail(a, for: 1)
        XCTAssertTrue(model.thumbnails[1] === a)
        model.seedThumbnail(a, for: 1)   // identical re-seed
        XCTAssertTrue(model.thumbnails[1] === a)
        model.seedThumbnail(b, for: 1)   // different frame
        XCTAssertTrue(model.thumbnails[1] === b)
    }

    func testSeedThumbnailBypassesActiveFreeze() {
        // The fast-switch fix: a cached seed applied WHILE frozen (a previous switch's slide is still
        // holding) must publish immediately, so the next Space's cached previews appear the instant it
        // slides in rather than being withheld until the freeze flushes.
        let model = SwitcherModel()
        let cached = NSImage()

        model.freezeThumbnails()
        model.seedThumbnail(cached, for: 3)

        XCTAssertTrue(model.thumbnails[3] === cached, "seed bypasses the freeze and publishes immediately")
    }

    func testSeedShownDuringSlideThenBufferedCaptureReplacesOnFlush() {
        // Seed (cached) is visible for the slide; a live capture of the same window that lands mid-slide
        // is buffered and replaces the seed only once the slide settles — no mid-slide content change.
        let model = SwitcherModel()
        let cached = NSImage()
        let fresh = NSImage()

        model.freezeThumbnails()
        model.seedThumbnail(cached, for: 4)   // immediate
        model.setThumbnail(fresh, for: 4)     // live capture during slide -> buffered

        XCTAssertTrue(model.thumbnails[4] === cached, "cached frame stays visible through the slide")

        model.flushThumbnails()
        XCTAssertTrue(model.thumbnails[4] === fresh, "fresh capture replaces it after the slide settles")
    }

    // MARK: - Grid layout setup

    func testGridSolvesTwoPerRow() {
        // The deterministic six-square setup: two cards per visual row across three rows, stacked
        // bottom-to-top so the first window (index 0) sits in the BOTTOM row. Visual top-to-bottom order
        // is [[4,5],[2,3],[0,1]]; entry lands on window 0 at the bottom (currentGridRow == 2).
        let model = sixSquareGridModel()
        XCTAssertEqual(model.gridLayout.rows, [[4, 5], [2, 3], [0, 1]])
        XCTAssertFalse(model.overflow)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.currentGridRow, 2)   // first window -> bottom row
        XCTAssertEqual(model.col, 0)
    }

    // MARK: - moveHorizontal (within the visual row)

    func testMoveHorizontalAdvancesWithinRow() {
        let model = sixSquareGridModel()         // entry: bottom row [0,1], selectedIndex 0

        model.moveHorizontal(1, wrap: false)

        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(model.currentGridRow, 2)
        XCTAssertEqual(model.col, 1)
    }

    func testMoveHorizontalClampsAtRowEnd() {
        let model = sixSquareGridModel()
        model.moveHorizontal(1, wrap: false)   // -> index 1 (last in the bottom row)

        model.moveHorizontal(1, wrap: false)   // clamp: stays on index 1, does NOT jump to another row

        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(model.currentGridRow, 2)
    }

    func testMoveHorizontalWrapsWithinRowOnly() {
        let model = sixSquareGridModel()
        model.moveHorizontal(1, wrap: false)   // index 1 (bottom row col 1)

        model.moveHorizontal(1, wrap: true)    // wraps within the bottom row back to col 0

        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.currentGridRow, 2)
    }

    // MARK: - moveVertical (between rows; edge -> Space switch). First window is in the bottom row, so a
    // swipe UP walks toward the top edge and a swipe DOWN from the bottom crosses to the previous Space.

    func testMoveVerticalUpMovesToRowAboveFirstCard() {
        let model = sixSquareGridModel()
        model.moveHorizontal(1, wrap: false)   // bottom row [0,1], col 1

        let result = model.moveVertical(1)     // up -> the row above

        XCTAssertEqual(result, .moved)
        XCTAssertEqual(model.currentGridRow, 1)
        XCTAssertEqual(model.selectedIndex, 2)   // first card of the row above ([2,3])
        XCTAssertEqual(model.col, 0)
    }

    func testMoveVerticalDownMovesToRowBelowFirstCard() {
        let model = sixSquareGridModel()
        model.setColumn(5)                      // top row [4,5], col 1

        let result = model.moveVertical(-1)     // down -> the row below

        XCTAssertEqual(result, .moved)
        XCTAssertEqual(model.currentGridRow, 1)
        XCTAssertEqual(model.selectedIndex, 2)   // first card of the row below ([2,3])
    }

    func testMoveVerticalUpAtTopRowReportsEdge() {
        let model = sixSquareGridModel()
        model.setColumn(4)                      // top row [4,5]

        let result = model.moveVertical(1)      // up past the top

        XCTAssertEqual(result, .atEdge(spaceDelta: 1))
        XCTAssertEqual(model.selectedIndex, 4)   // selection unchanged
    }

    func testMoveVerticalDownAtBottomRowReportsEdge() {
        let model = sixSquareGridModel()        // entry: bottom row [0,1], selectedIndex 0

        let result = model.moveVertical(-1)     // down past the bottom

        XCTAssertEqual(result, .atEdge(spaceDelta: -1))
        XCTAssertEqual(model.selectedIndex, 0)   // selection unchanged
    }

    // MARK: - Entering a Space resets to the first window (bottom-left)

    func testSetRowResetsGridToFirstWindowBottomLeft() {
        // Two Spaces, each six squares; start on Space 0 up in the grid, switch Space -> first window
        // (bottom-left of the new Space's grid).
        let model = SwitcherModel()
        model.setCanvas(CGSize(width: 250, height: 400))
        let square = CGRect(x: 0, y: 0, width: 300, height: 300)
        let spaceA = (0..<6).map { makeWindow(id: CGWindowID(100 + $0), spaceID: 1, realFrame: square) }
        let spaceB = (0..<6).map { makeWindow(id: CGWindowID(200 + $0), spaceID: 2, realFrame: square) }
        model.setRows([spaceA, spaceB], labels: ["1", "2"], startRow: 0, column: 0)
        model.setColumn(5)                      // top row of Space 0
        XCTAssertEqual(model.currentGridRow, 0)

        model.setRow(1)                         // switch to Space 1

        XCTAssertEqual(model.currentRow, 1)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.currentGridRow, 2)   // first window sits in the bottom row
        XCTAssertEqual(model.col, 0)
        XCTAssertEqual(model.windows.map(\.id).first, 200)
    }
}
