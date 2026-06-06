import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the launcher's 2D navigation model: a grid cursor that can rise onto the headers row,
/// where horizontal switches the batch and down re-enters the grid. Columns come from
/// `LauncherGridLayout.columns`.
@MainActor
final class LauncherModelTests: XCTestCase {
    private let cols = LauncherGridLayout.columns

    private func item(_ name: String) -> LaunchItem {
        LaunchItem(title: name, icon: .appDefault,
                   kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), strategy: nil))
    }

    /// Build a model with band 0 holding `count0` items and band 1 holding `count1`, focus reset.
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

    func testInitialIsFirstAppOfFirstBand() {
        let m = makeModel(count0: 8, count1: 3)
        XCTAssertEqual(m.focus, .grid)
        XCTAssertEqual(m.currentBand, 0)
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.selectedItem?.title, "A0")
    }

    func testGridHorizontalMovesWithinRowThenClamps() {
        let m = makeModel(count0: 8, count1: 3)         // row0 = indices 0..5 (full)
        m.stepHorizontal(1)
        XCTAssertEqual(m.selectedIndex, 1)
        // jump to the last column of row 0, then one more clamps (col 6 is out of the row).
        for _ in 0..<10 { m.stepHorizontal(1) }
        XCTAssertEqual(m.selectedIndex, cols - 1, "clamps at the right end of the row")
        for _ in 0..<10 { m.stepHorizontal(-1) }
        XCTAssertEqual(m.selectedIndex, 0, "clamps at the left end of the row")
    }

    func testGridVerticalDownMovesARow() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepVertical(-1)                               // down
        XCTAssertEqual(m.selectedIndex, cols, "down from (row0,col0) lands on (row1,col0)")
        m.stepVertical(-1)                               // already last row → clamp
        XCTAssertEqual(m.selectedIndex, cols)
    }

    func testGridUpFromFirstRowRisesToHeaders() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepVertical(1)                                // up from row 0
        XCTAssertEqual(m.focus, .headers)
        XCTAssertNil(m.selectedItem, "no app is selected while on the headers row")
    }

    func testHeaderHorizontalSwitchesBatch() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepVertical(1)                                // → headers
        m.stepHorizontal(1)                              // switch batch
        XCTAssertEqual(m.focus, .headers)
        XCTAssertEqual(m.currentBand, 1)
        XCTAssertEqual(m.items.first?.title, "B0", "the displayed grid is now band 1")
        m.stepHorizontal(1)                              // clamp at last band
        XCTAssertEqual(m.currentBand, 1)
        m.stepHorizontal(-1)
        XCTAssertEqual(m.currentBand, 0)
    }

    func testHeaderDownEntersThatBatch() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepVertical(1)                                // → headers
        m.stepHorizontal(1)                              // band 1
        m.stepVertical(-1)                               // down → enter grid
        XCTAssertEqual(m.focus, .grid)
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.selectedItem?.title, "B0")
    }

    func testRoundTripHeadersAndBack() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepVertical(-1)                               // (row1,col0)
        XCTAssertEqual(m.selectedIndex, cols)
        m.stepVertical(1)                                // back to row 0
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.focus, .grid)
        m.stepVertical(1)                                // up again → headers
        XCTAssertEqual(m.focus, .headers)
    }

    func testHorizontalInShortLastRowClamps() {
        let m = makeModel(count0: 8, count1: 3)          // row1 has 2 items (indices 6,7)
        m.stepVertical(-1)                               // to index 6 (row1,col0)
        m.stepHorizontal(1)
        XCTAssertEqual(m.selectedIndex, cols + 1, "moves to the 2nd item in the short row")
        m.stepHorizontal(1)
        XCTAssertEqual(m.selectedIndex, cols + 1, "clamps — the short row has no 3rd item")
    }

    func testHeaderUpDoesNothing() {
        let m = makeModel(count0: 8, count1: 3)
        m.stepVertical(1)                                // → headers
        m.stepVertical(1)                                // up again — already at top
        XCTAssertEqual(m.focus, .headers)
    }
}
