import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for the uniform-scale grid solve in `SwitcherLayout` (naturalSize / cardSizes / wrap /
/// solveGrid). The solve gives every window one shared scale applied to its real frame, wraps the
/// cards into rows that fill the canvas width, and picks the largest scale that still fits the canvas
/// height (capped at `kMax`, floored per-card at `minCardHeight`).
final class SwitcherLayoutTests: XCTestCase {

    private let eps: CGFloat = 1e-6

    // MARK: - naturalSize (D7 fallback chain)

    func testNaturalSizePrefersRealFrame() {
        let n = SwitcherLayout.naturalSize(
            realFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        XCTAssertEqual(n.width, 1600, accuracy: eps)
        XCTAssertEqual(n.height, 900, accuracy: eps)
    }

    func testNaturalSizeFallsBackToDisplayedFrame() {
        let n = SwitcherLayout.naturalSize(
            realFrame: .zero,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )
        XCTAssertEqual(n.width, 640, accuracy: eps)
        XCTAssertEqual(n.height, 480, accuracy: eps)
    }

    func testNaturalSizeDefaultsWhenNoUsableFrame() {
        let n = SwitcherLayout.naturalSize(realFrame: .zero, frame: .zero)
        XCTAssertEqual(n, SwitcherLayout.defaultNaturalSize)
    }

    // MARK: - cardSizes (uniform scale + floor)

    func testCardSizesApplyUniformScale() {
        let naturals = [CGSize(width: 1000, height: 800), CGSize(width: 500, height: 400)]
        let sizes = SwitcherLayout.cardSizes(naturals: naturals, scale: 0.3)
        XCTAssertEqual(sizes[0].width, 300, accuracy: eps)
        XCTAssertEqual(sizes[0].height, 240, accuracy: eps)
        XCTAssertEqual(sizes[1].width, 150, accuracy: eps)
        XCTAssertEqual(sizes[1].height, 120, accuracy: eps)
    }

    func testCardSizesFloorWidensProportionally() {
        // 400x300 at scale 0.1 -> 40x30; height floors to minCardHeight, width scales by the same factor
        // so the aspect (4:3) is preserved.
        let sizes = SwitcherLayout.cardSizes(naturals: [CGSize(width: 400, height: 300)], scale: 0.1)
        XCTAssertEqual(sizes[0].height, SwitcherLayout.minCardHeight, accuracy: eps)
        let aspect = sizes[0].width / sizes[0].height
        XCTAssertEqual(aspect, 400.0 / 300.0, accuracy: 1e-3)
    }

    // MARK: - wrap (row breaks + content size)

    func testWrapBreaksRowsAtCanvasWidth() {
        // Four 96-wide cards, spacing 16, canvas 250: 96 + 16 + 96 = 208 fits two; a third would be
        // 208 + 16 + 96 = 320 > 250 -> wraps. So two per row.
        let sizes = Array(repeating: CGSize(width: 96, height: 96), count: 4)
        let (rows, content) = SwitcherLayout.wrap(sizes: sizes, canvasWidth: 250)
        XCTAssertEqual(rows, [[0, 1], [2, 3]])
        // content width = widest row = 96 + 16 + 96 = 208; height = 2 bands of 96 + one rowSpacing.
        XCTAssertEqual(content.width, 208, accuracy: eps)
        XCTAssertEqual(content.height, 96 * 2 + SwitcherLayout.gridRowSpacing, accuracy: eps)
    }

    func testWrapKeepsOrderAndSingleRowWhenItFits() {
        let sizes = Array(repeating: CGSize(width: 96, height: 96), count: 3)
        let (rows, _) = SwitcherLayout.wrap(sizes: sizes, canvasWidth: 1000)
        XCTAssertEqual(rows, [[0, 1, 2]])
    }

    func testWrapEmptyIsEmpty() {
        let (rows, content) = SwitcherLayout.wrap(sizes: [], canvasWidth: 500)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(content, .zero)
    }

    // MARK: - wrap: balanced rows (minimax partition, not greedy)

    func testWrapBalancesLonelyLastRow() {
        // Five 96-wide cards in a canvas that fits four (96*4 + 16*3 = 432 <= 440, a fifth overflows):
        // greedy would give a lonely [4][1]; balanced gives [3][2].
        let sizes = Array(repeating: CGSize(width: 96, height: 96), count: 5)
        let (rows, _) = SwitcherLayout.wrap(sizes: sizes, canvasWidth: 440)
        XCTAssertEqual(rows, [[0, 1, 2], [3, 4]])
    }

    func testWrapNineCardsBalanceToThreeEvenRows() {
        // Nine cards that fit four per row: greedy [4][4][1] -> balanced [3][3][3].
        let sizes = Array(repeating: CGSize(width: 96, height: 96), count: 9)
        let (rows, _) = SwitcherLayout.wrap(sizes: sizes, canvasWidth: 440)
        XCTAssertEqual(rows, [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
    }

    func testWrapLeavesAlreadyEvenRowsAlone() {
        // Eight cards, four per row: greedy [4][4] is already balanced and is left unchanged.
        let sizes = Array(repeating: CGSize(width: 96, height: 96), count: 8)
        let (rows, _) = SwitcherLayout.wrap(sizes: sizes, canvasWidth: 440)
        XCTAssertEqual(rows, [[0, 1, 2, 3], [4, 5, 6, 7]])
    }

    func testWrapLeavesFineSingleRowAlone() {
        // Four cards that all fit one row stay a single row (minimum rows == 1: never force a break).
        let sizes = Array(repeating: CGSize(width: 96, height: 96), count: 4)
        let (rows, _) = SwitcherLayout.wrap(sizes: sizes, canvasWidth: 440)
        XCTAssertEqual(rows, [[0, 1, 2, 3]])
    }

    // MARK: - solveGrid

    func testSolvePreservesRelativeSizesWithOneScale() {
        // A 1000x1000 and a 500x500 window in a roomy canvas: both at one scale -> 2:1 in both dims.
        let naturals = [CGSize(width: 1000, height: 1000), CGSize(width: 500, height: 500)]
        let layout = SwitcherLayout.solveGrid(naturals: naturals, canvas: CGSize(width: 2000, height: 600))
        XCTAssertEqual(layout.sizes[0].width / layout.sizes[1].width, 2, accuracy: 1e-3)
        XCTAssertEqual(layout.sizes[0].height / layout.sizes[1].height, 2, accuracy: 1e-3)
        XCTAssertFalse(layout.overflowsVertically)
    }

    func testSolveCapsAtKMax() {
        // One window, huge canvas: scale is capped at kMax (won't balloon to fill).
        let layout = SwitcherLayout.solveGrid(
            naturals: [CGSize(width: 1000, height: 800)],
            canvas: CGSize(width: 4000, height: 3000)
        )
        XCTAssertEqual(layout.scale, SwitcherLayout.kMax, accuracy: 1e-3)
        XCTAssertEqual(layout.sizes[0].height, 800 * SwitcherLayout.kMax, accuracy: 1e-2)
    }

    func testSolveFloorsTinyWindowToMinCardHeight() {
        // A 100x100 window at kMax is 32pt tall -> floored to the readable minimum.
        let layout = SwitcherLayout.solveGrid(
            naturals: [CGSize(width: 100, height: 100)],
            canvas: CGSize(width: 2000, height: 2000)
        )
        XCTAssertEqual(layout.sizes[0].height, SwitcherLayout.minCardHeight, accuracy: eps)
    }

    func testSolveProducesKnownGrid() {
        // Six 300x300 windows, canvas 250 wide x 400 tall: at kMax each card is 96x96 (300*0.32),
        // two fit per row, three rows fit the height. Stacked bottom-to-top (the first window lands in
        // the bottom row), visual top-to-bottom order is [[4,5],[2,3],[0,1]], no overflow.
        let naturals = Array(repeating: CGSize(width: 300, height: 300), count: 6)
        let layout = SwitcherLayout.solveGrid(naturals: naturals, canvas: CGSize(width: 250, height: 400))
        XCTAssertEqual(layout.rows, [[4, 5], [2, 3], [0, 1]])
        XCTAssertEqual(layout.scale, SwitcherLayout.kMax, accuracy: 1e-3)
        XCTAssertFalse(layout.overflowsVertically)
    }

    func testSolveFlagsVerticalOverflow() {
        // Ten 300x300 windows, two per row -> five rows of >=96pt bands cannot fit a 100pt-tall canvas
        // even at the floor: overflow flagged so the view scrolls.
        let naturals = Array(repeating: CGSize(width: 300, height: 300), count: 10)
        let layout = SwitcherLayout.solveGrid(naturals: naturals, canvas: CGSize(width: 250, height: 100))
        XCTAssertTrue(layout.overflowsVertically)
        XCTAssertGreaterThan(layout.contentSize.height, 100)
    }

    func testSolveEmptyForNoWindows() {
        let layout = SwitcherLayout.solveGrid(naturals: [], canvas: CGSize(width: 800, height: 600))
        XCTAssertEqual(layout, .empty)
    }

    // MARK: - Configurable window size (the Hub "Window size" slider)

    func testSolveHonorsMaxScale() {
        // One window in a roomy canvas: the scale equals the supplied cap, so a larger cap -> bigger
        // cards and a smaller cap -> smaller cards (the slider's lever).
        let naturals = [CGSize(width: 1000, height: 800)]
        let canvas = CGSize(width: 4000, height: 3000)

        let big = SwitcherLayout.solveGrid(naturals: naturals, canvas: canvas, maxScale: 0.40)
        let small = SwitcherLayout.solveGrid(naturals: naturals, canvas: canvas, maxScale: 0.12)

        XCTAssertEqual(big.scale, 0.40, accuracy: 1e-3)
        XCTAssertEqual(small.scale, 0.12, accuracy: 1e-3)
        XCTAssertGreaterThan(big.sizes[0].height, small.sizes[0].height)
    }
}
