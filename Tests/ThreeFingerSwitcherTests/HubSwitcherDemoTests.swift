import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for the §12 Window-Switcher teaching preview: the deterministic teaching gesture grammar (the
/// autoplay script the ghost hand loops), the activation-threshold → open-swipe-length mapping, and the
/// `HubSwitcherDemo` holder that seeds the real `SwitcherModel` the (static) preview renders.
@MainActor
final class HubSwitcherDemoTests: XCTestCase {

    private func window(_ id: CGWindowID, _ name: String) -> WindowInfo {
        WindowInfo(id: id, pid: 0, appName: name, title: name, appIcon: nil,
                   frame: CGRect(x: 0, y: 0, width: 1280, height: 800), axElement: nil,
                   isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
    }

    /// A holder seeded with two Space-rows (3 windows on the home row, 2 above).
    private func seededDemo() -> HubSwitcherDemo {
        let canvas = CGSize(width: 820, height: 150)
        let source = SwitcherModel()
        source.setCanvas(canvas)
        source.setRows([[window(1, "A"), window(2, "B"), window(3, "C")],
                        [window(4, "D"), window(5, "E")]],
                       labels: ["1", "2"], startRow: 0, column: 0)
        let demo = HubSwitcherDemo()
        demo.seed(from: source, canvas: canvas, maxScale: SwitcherLayout.kMax)
        return demo
    }

    func testTeachingGestureGrammar() {
        let g = HubSwitcherDemo.teachingGesture(openLength: 0.3)
        XCTAssertEqual(g.strokes.map(\.fingers), [3, 2, 2, 2],
                       "open on three fingers, then lift one and navigate on two")
        // Open + the two vertical strokes are CONNECTED (no lift between): gapAfter 0.
        XCTAssertEqual(g.strokes[0].gapAfter, 0, "the open is connected to the navigation (lift one finger)")
        XCTAssertEqual(g.strokes[1].gapAfter, 0)
        XCTAssertEqual(g.strokes[2].gapAfter, 0)
        XCTAssertNil(g.strokes[3].gapAfter, "the final sideways scrub lifts (default gap) so the demo loops")
    }

    func testOpenLengthTracksActivationThreshold() {
        let short = HubSwitcherDemo.openLength(forActivation: 0.01)
        let long = HubSwitcherDemo.openLength(forActivation: 0.15)
        XCTAssertLessThan(short, long, "a larger activation threshold demos a longer opening swipe")
        XCTAssertEqual(HubSwitcherDemo.openLength(forActivation: 0.5), long, accuracy: 1e-9,
                       "clamps above the max threshold")
        XCTAssertEqual(HubSwitcherDemo.openLength(forActivation: -1), short, accuracy: 1e-9,
                       "clamps below the min threshold")
    }

    func testSeedLandsOnHomeRowFirstWindow() {
        let demo = seededDemo()
        XCTAssertEqual(demo.model.currentRow, 0, "the seeded preview rests on the home (bottom) row")
        XCTAssertEqual(demo.model.selectedIndex, 0, "the seeded preview highlights the first window")
        XCTAssertEqual(demo.model.rowCount, 2, "both Space-rows are seeded")
    }

    func testSetMaxScaleResolvesGrid() {
        let demo = seededDemo()
        let before = demo.model.gridLayout.contentSize
        demo.setMaxScale(SwitcherLayout.kMax * 2.0)
        let after = demo.model.gridLayout.contentSize
        XCTAssertNotEqual(before, after, "raising the window-scale re-solves the grid to larger cards")
    }
}
