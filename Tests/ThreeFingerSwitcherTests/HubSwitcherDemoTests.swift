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

    // MARK: - Sync drive (the miniature follows the ghost hand)

    private func pose(_ stroke: Int, _ fraction: Double,
                      lifted: Bool = false, hovering: Bool = false) -> GhostSyncPose {
        GhostSyncPose(strokeIndex: stroke,
                      tick: Int(fraction * Double(GhostSyncPose.ticksPerStroke)),
                      lifted: lifted, hovering: hovering)
    }

    /// One full teaching loop: the commit lift hides the panel, the next open swipe quietly resets and then
    /// pops it back in at the activation beat, up/down slide the Space reel there and back, the sideways
    /// scrub steps the highlight, and the final lift commits again.
    func testDriveTeachingLoopFollowsGhostHand() {
        let demo = seededDemo()

        // End of a previous loop: the lift commits — the panel pops out.
        demo.drive(pose(3, 1.0, lifted: true), script: .teaching)
        XCTAssertFalse(demo.overlayShown, "the commit lift hides the mini switcher")

        // Early open swipe (under the activation beat): still hidden, model quietly reset.
        demo.drive(pose(0, 0.2), script: .teaching)
        XCTAssertFalse(demo.overlayShown)
        XCTAssertEqual(demo.model.currentRow, 0)
        XCTAssertEqual(demo.model.selectedIndex, 0)

        // Crossing the beat pops the switcher in.
        demo.drive(pose(0, 0.8), script: .teaching)
        XCTAssertTrue(demo.overlayShown, "the open swipe reveals the switcher at the activation beat")

        // The up stroke slides to the second Space-row at mid-stroke — not before.
        demo.drive(pose(1, 0.3), script: .teaching)
        XCTAssertEqual(demo.model.currentRow, 0, "the row holds until the stroke commits")
        demo.drive(pose(1, 0.7), script: .teaching)
        XCTAssertEqual(demo.model.currentRow, 1, "the up stroke slides the reel to the second Space")

        // The down stroke returns home.
        demo.drive(pose(2, 0.7), script: .teaching)
        XCTAssertEqual(demo.model.currentRow, 0, "the down stroke slides the reel back")

        // The sideways scrub steps the highlight rightward across the home row.
        demo.drive(pose(3, 0.95), script: .teaching)
        XCTAssertGreaterThan(demo.model.selectedIndex, 0, "the scrub steps the highlight across the row")

        // And the lift commits again.
        demo.drive(pose(3, 1.0, lifted: true), script: .teaching)
        XCTAssertFalse(demo.overlayShown)
    }

    /// Repeated frames are idempotent: replaying the same quantized pose leaves the model untouched, so
    /// resumed / duplicated sync frames can land anywhere in the loop without corrupting the story.
    func testDriveFramesAreIdempotent() {
        let demo = seededDemo()
        demo.drive(pose(0, 0.8), script: .teaching)
        demo.drive(pose(1, 0.7), script: .teaching)
        let row = demo.model.currentRow
        let sel = demo.model.selectedIndex
        demo.drive(pose(1, 0.7), script: .teaching)
        demo.drive(pose(1, 0.8), script: .teaching)
        XCTAssertEqual(demo.model.currentRow, row, "replayed up-stroke frames don't re-slide the reel")
        XCTAssertEqual(demo.model.selectedIndex, sel)
    }

    /// The windows-axis hover script scrubs the highlight without ever touching the Space row; the spaces
    /// hover script slides the reel up and back without scrubbing.
    func testHoverScriptsDriveTheirOwnAxis() {
        let demo = seededDemo()
        demo.drive(pose(0, 0.8, hovering: true), script: .windowsHover)
        demo.drive(pose(1, 0.95, hovering: true), script: .windowsHover)
        XCTAssertEqual(demo.model.currentRow, 0, "the windows hover never changes the Space row")
        XCTAssertGreaterThan(demo.model.selectedIndex, 0, "the windows hover scrubs the highlight")

        demo.drive(pose(1, 1.0, lifted: true, hovering: true), script: .windowsHover)
        demo.drive(pose(0, 0.2, hovering: true), script: .spacesHover)   // reset beat
        demo.drive(pose(0, 0.8, hovering: true), script: .spacesHover)
        demo.drive(pose(1, 0.7, hovering: true), script: .spacesHover)
        XCTAssertEqual(demo.model.currentRow, 1, "the spaces hover slides the reel up")
        demo.drive(pose(2, 0.7, hovering: true), script: .spacesHover)
        XCTAssertEqual(demo.model.currentRow, 0, "…and back down")
    }
}
