import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the launcher's transposed 2D navigation model: the band titles are a **vertical list on
/// the LEFT** (focus `.bands`) and the active band's content is a **grid on the RIGHT** (focus
/// `.grid`). On the band list, **vertical** switches the active band; crossing between the band list
/// and the grid is **horizontal** (right enters the grid, left from column 0 returns to the list).
/// Inside the grid, horizontal moves across a row and vertical moves between rows (clamped at row 0 —
/// it no longer rises to a header strip). Columns come from `LauncherGridLayout.columns`.
@MainActor
final class LauncherModelTests: XCTestCase {
    private let cols = LauncherGridLayout.columns

    private func item(_ name: String) -> LaunchItem {
        LaunchItem(title: name, icon: .appDefault,
                   kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), strategy: nil))
    }

    /// Build a model with band 0 holding `count0` items and band 1 holding `count1`, focus reset.
    /// Two bands → lands on the band list (`.bands`).
    private func makeModel(count0: Int, count1: Int) -> LauncherModel {
        let m = LauncherModel()
        let b0 = (0..<count0).map { item("A\($0)") }
        let b1 = (0..<count1).map { item("B\($0)") }
        m.setBands([b0, b1],
                   names: ["Dev", "Comms"],
                   colors: [ItemColor(red: 0, green: 0, blue: 1), ItemColor(red: 0, green: 1, blue: 0)],
                   startBand: 0, column: 0)
        return m
    }

    /// Build a single-band model — no band list, so it lands directly on the grid's home cell.
    private func makeSingleBandModel(count: Int) -> LauncherModel {
        let m = LauncherModel()
        let b0 = (0..<count).map { item("A\($0)") }
        m.setBands([b0], names: ["Dev"], colors: [ItemColor(red: 0, green: 0, blue: 1)],
                   startBand: 0, column: 0)
        return m
    }

    // MARK: - Landing

    func testMultiBandLandsOnBandList() {
        let m = makeModel(count0: 8, count1: 3)
        XCTAssertEqual(m.focus, .bands, "multi-band lands on the band-title list")
        XCTAssertEqual(m.currentBand, 0, "on the home band")
        XCTAssertNil(m.selectedItem, "nothing is armable while on the band list")
    }

    func testSingleBandLandsOnFirstItem() {
        let m = makeSingleBandModel(count: 8)
        XCTAssertEqual(m.focus, .grid, "a single band has no list — it lands on the grid")
        XCTAssertEqual(m.currentBand, 0)
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.selectedItem?.title, "A0")
    }

    // MARK: - Band list: vertical switches bands, clamps at the ends

    func testBandListVerticalSwitchesBandsAndClamps() {
        let m = makeModel(count0: 8, count1: 3)
        // down (dir < 0) = next band; the active band and its content follow.
        m.stepVertical(-1)
        XCTAssertEqual(m.focus, .bands, "still on the band list while switching bands")
        XCTAssertEqual(m.currentBand, 1)
        XCTAssertEqual(m.items.first?.title, "B0", "the content pane is now band 1")
        m.stepVertical(-1)                               // already the last band → clamp
        XCTAssertEqual(m.currentBand, 1, "clamps at the last band (no wrap)")
        // up (dir > 0) = previous band, back to band 0, then clamp.
        m.stepVertical(1)
        XCTAssertEqual(m.currentBand, 0)
        XCTAssertEqual(m.items.first?.title, "A0")
        m.stepVertical(1)                                // already the first band → clamp
        XCTAssertEqual(m.currentBand, 0, "clamps at the first band (no wrap)")
        XCTAssertEqual(m.focus, .bands)
    }

    // MARK: - Crossing: band list ⇄ grid via horizontal

    func testBandListRightCrossesIntoGridAtItemZero() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepHorizontal(1)                              // right → enter the grid at item 0
        XCTAssertEqual(m.focus, .grid)
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.selectedItem?.title, "A0", "lands on the band's home/first item")
    }

    func testBandListLeftClamps() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepHorizontal(-1)                             // left → nothing sits left of the band list
        XCTAssertEqual(m.focus, .bands, "left from the band list clamps (stays on the list)")
        XCTAssertEqual(m.currentBand, 0)
    }

    func testGridColumnZeroLeftReturnsToBandList() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepHorizontal(1)                              // enter the grid (col 0)
        XCTAssertEqual(m.focus, .grid)
        m.stepHorizontal(-1)                             // left from column 0 → back to the band list
        XCTAssertEqual(m.focus, .bands)
        XCTAssertEqual(m.currentBand, 0, "returns at the active band's title")
        XCTAssertNil(m.selectedItem)
    }

    func testGridColumnZeroLeftClampsWhenSingleBand() {
        let m = makeSingleBandModel(count: 8)            // one band → nothing to cross back to
        XCTAssertEqual(m.focus, .grid)
        m.stepHorizontal(-1)                             // left from column 0 with only one band → clamp
        XCTAssertEqual(m.focus, .grid, "single band: there is no band list to return to")
        XCTAssertEqual(m.selectedIndex, 0)
    }

    // MARK: - Grid stepping (unchanged within the grid)

    func testGridHorizontalMovesWithinRowThenClamps() {
        let m = makeSingleBandModel(count: 8)            // row0 = indices 0..5 (full), single band
        m.stepHorizontal(1)
        XCTAssertEqual(m.selectedIndex, 1)
        // jump to the last column of row 0, then one more clamps (col 6 is out of the row).
        for _ in 0..<10 { m.stepHorizontal(1) }
        XCTAssertEqual(m.selectedIndex, cols - 1, "clamps at the right end of the row")
        for _ in 0..<10 { m.stepHorizontal(-1) }
        XCTAssertEqual(m.selectedIndex, 0, "clamps at the left end of the row (single band, no cross-back)")
    }

    func testGridVerticalDownMovesARow() {
        let m = makeSingleBandModel(count: 8)
        m.stepVertical(-1)                               // down
        XCTAssertEqual(m.selectedIndex, cols, "down from (row0,col0) lands on (row1,col0)")
        m.stepVertical(-1)                               // already last row → clamp
        XCTAssertEqual(m.selectedIndex, cols)
    }

    func testGridUpFromFirstRowClamps() {
        let m = makeSingleBandModel(count: 8)
        m.stepVertical(1)                                // up from row 0 → clamp (no rise to a header strip)
        XCTAssertEqual(m.focus, .grid, "vertical up from row 0 stays in the grid")
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.selectedItem?.title, "A0")
    }

    func testGridVerticalRoundTripRowZeroClamps() {
        let m = makeSingleBandModel(count: 8)
        m.stepVertical(-1)                               // (row1,col0)
        XCTAssertEqual(m.selectedIndex, cols)
        m.stepVertical(1)                                // back to row 0
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.focus, .grid)
        m.stepVertical(1)                                // up again from row 0 → clamps (no header strip)
        XCTAssertEqual(m.focus, .grid)
        XCTAssertEqual(m.selectedIndex, 0)
    }

    func testHorizontalInShortLastRowClamps() {
        let m = makeSingleBandModel(count: 8)            // row1 has 2 items (indices 6,7)
        m.stepVertical(-1)                               // to index 6 (row1,col0)
        m.stepHorizontal(1)
        XCTAssertEqual(m.selectedIndex, cols + 1, "moves to the 2nd item in the short row")
        m.stepHorizontal(1)
        XCTAssertEqual(m.selectedIndex, cols + 1, "clamps — the short row has no 3rd item")
    }

    // MARK: - Window height accounts for the band-icon list (no mid-switch stretch jitter)

    func testWindowHeightNeverBelowTheBandListDemand() {
        // Ten bands of fixed-size icons need more height than a one-row band's grid — the
        // container must size to the list in ONE computation, not re-stretch after fitting rows.
        let oneRowGrid = LauncherGridLayout.containerHeight(forItemCount: 3)
        let list = LauncherGridLayout.bandListHeight(bandCount: 10)
        XCTAssertGreaterThan(list, oneRowGrid, "precondition: many bands out-demand a short band")
        XCTAssertEqual(LauncherGridLayout.windowHeight(itemCount: 3, bandCount: 10), list,
                       "the larger demand wins")
    }

    func testWindowHeightStableAcrossShortBandsWithManyBands() {
        // Scrubbing between two short bands must not change the height when the list dominates.
        let a = LauncherGridLayout.windowHeight(itemCount: 2, bandCount: 9)
        let b = LauncherGridLayout.windowHeight(itemCount: 7, bandCount: 9)
        XCTAssertEqual(a, b, "the band list sets the floor; short bands share one height")
    }

    func testWindowHeightStillGrowsForTallBandsAndClampsAtMax() {
        let tall = LauncherGridLayout.windowHeight(itemCount: 24, bandCount: 9)
        XCTAssertGreaterThan(tall, LauncherGridLayout.bandListHeight(bandCount: 9),
                             "a genuinely tall band still out-grows the list")
        XCTAssertLessThanOrEqual(LauncherGridLayout.windowHeight(itemCount: 200, bandCount: 40),
                                 LauncherGridLayout.maxHeight, "the max is the ceiling for both demands")
    }

    func testSingleBandHasNoListDemand() {
        XCTAssertEqual(LauncherGridLayout.bandListHeight(bandCount: 1), 0, "no list shown for one band")
        XCTAssertEqual(LauncherGridLayout.windowHeight(itemCount: 3, bandCount: 1),
                       LauncherGridLayout.windowHeight(itemCount: 3), "default matches the no-list case")
    }

    // MARK: - Files band layout = the Clipboard container's EXACT dimensions (refinement 3)

    func testFilesBandContainerEqualsClipboardDimensionsExactly() {
        // The Files navigator's container is a FIXED size equal to the Clipboard band's — so it never
        // resizes or moves when crossing in or changing depth (the list scrolls inside instead).
        XCTAssertEqual(FilesBandLayout.containerWidth, ClipboardBandLayout.containerWidth,
                       "the Files container width is the Clipboard width, exactly")
        XCTAssertEqual(FilesBandLayout.containerHeight, ClipboardBandLayout.containerHeight,
                       "the Files container height is the Clipboard height, exactly")
    }

    func testFilesBandInteriorPanesSumToTheFixedContainerWidth() {
        // rail + current list + preview + the two dividers + the outer padding == the fixed container width,
        // so the three panes lay out WITHIN the fixed width with no overflow and no dead space.
        let sum = FilesBandLayout.ancestorRailWidth
            + FilesBandLayout.currentColumnWidth
            + FilesBandLayout.previewWidth
            + 2 * FilesBandLayout.dividerWidth
            + 2 * FilesBandLayout.padding
        XCTAssertEqual(sum, FilesBandLayout.containerWidth, accuracy: 0.01,
                       "the three-pane split fills the fixed container exactly")
        XCTAssertGreaterThan(FilesBandLayout.previewWidth, FilesBandLayout.currentColumnWidth,
                             "the preview fills the roomy remainder — wider than the current list")
    }

    func testFilesBandRowAreaIsContainerMinusChrome() {
        // The scrollable row area is the fixed container height minus the breadcrumb bar and the outer
        // padding — and a denser row fits MORE rows in that same fixed area (the container never grows for
        // density; only how many rows show before it scrolls changes).
        XCTAssertEqual(FilesBandLayout.rowAreaHeight,
                       FilesBandLayout.containerHeight
                        - FilesBandLayout.breadcrumbBarHeight - 2 * FilesBandLayout.padding,
                       accuracy: 0.01)
        XCTAssertGreaterThan(FilesBandLayout.visibleRowCount(for: .compact),
                             FilesBandLayout.visibleRowCount(for: .spacious),
                             "a tighter row packs more rows into the same fixed row area")
    }
}
