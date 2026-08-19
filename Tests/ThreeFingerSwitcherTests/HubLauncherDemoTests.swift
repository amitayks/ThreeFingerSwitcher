import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for the §13 Launcher teaching preview's sync drive: the `HubLauncherDemo` holder stepping its real
/// `LauncherModel` in time with the ghost hand's quantized sync frames (the same clockless seam the Switcher
/// preview uses), plus the journey-gesture grammar the band pages play.
@MainActor
final class HubLauncherDemoTests: XCTestCase {

    private func item(_ name: String) -> LaunchItem {
        LaunchItem(title: name, icon: .appDefault,
                   kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), strategy: nil))
    }

    /// A source launcher with three bands (4 + 3 + 2 items), the shape a band journey traverses.
    private func sourceModel() -> LauncherModel {
        let m = LauncherModel()
        m.setBands([(0..<4).map { item("A\($0)") },
                    (0..<3).map { item("B\($0)") },
                    (0..<2).map { item("C\($0)") }],
                   names: ["Dev", "Comms", "Clipboard"],
                   colors: [ItemColor(red: 0, green: 0, blue: 1),
                            ItemColor(red: 0, green: 1, blue: 0),
                            ItemColor(red: 1, green: 0, blue: 0)],
                   startBand: 0, column: 0)
        return m
    }

    private func seededDemo(landOnLastBand: Bool = false) -> HubLauncherDemo {
        let demo = HubLauncherDemo()
        demo.seed(from: sourceModel(), landOnLastBand: landOnLastBand)
        return demo
    }

    private func pose(_ stroke: Int, _ fraction: Double,
                      lifted: Bool = false, hovering: Bool = false) -> GhostSyncPose {
        GhostSyncPose(strokeIndex: stroke,
                      tick: Int(fraction * Double(GhostSyncPose.ticksPerStroke)),
                      lifted: lifted, hovering: hovering)
    }

    // MARK: - Gesture grammar

    func testBandJourneyGestureIsOpenPlusTraverse() {
        let plain = HubLauncherDemo.bandJourneyGesture(openLength: 0.3)
        XCTAssertEqual(plain.strokes.map(\.fingers), [4, 2], "open + traverse only")
    }

    func testVerticalStrokesDescendInYUpCoordinates() {
        // "Down the band list" must render downward on the pad: y-up coordinates, so to.y < from.y.
        let teaching = HubLauncherDemo.teachingGesture(openLength: 0.3)
        XCTAssertLessThan(teaching.strokes[1].to.y, teaching.strokes[1].from.y,
                          "the teaching band step travels DOWN the pad")
        let journey = HubLauncherDemo.bandJourneyGesture(openLength: 0.3)
        XCTAssertLessThan(journey.strokes[1].to.y, journey.strokes[1].from.y,
                          "the band-list traverse travels DOWN the pad")
    }

    // MARK: - Teaching drive (the Launcher page)

    func testDriveTeachingLoopFollowsGhostHand() {
        let demo = seededDemo()

        // End of a previous loop: the closing lift hides the panel.
        demo.drive(pose(2, 1.0, lifted: true), script: .teaching)
        XCTAssertFalse(demo.overlayShown, "the closing lift hides the mini launcher")

        // Early open swipe: still hidden, quietly reset to the journey start (home band, band rail).
        demo.drive(pose(0, 0.2), script: .teaching)
        XCTAssertFalse(demo.overlayShown)
        XCTAssertEqual(demo.model.currentBand, 0)
        XCTAssertEqual(demo.model.focus, .bands)

        // Crossing the activation beat pops the launcher in.
        demo.drive(pose(0, 0.8), script: .teaching)
        XCTAssertTrue(demo.overlayShown, "the open swipe reveals the launcher at the activation beat")

        // The band stroke steps DOWN one band at mid-stroke — not before.
        demo.drive(pose(1, 0.3), script: .teaching)
        XCTAssertEqual(demo.model.currentBand, 0, "the band holds until the stroke commits")
        demo.drive(pose(1, 0.7), script: .teaching)
        XCTAssertEqual(demo.model.currentBand, 1, "the band stroke steps to the next band")
        XCTAssertEqual(demo.model.focus, .bands, "still on the band rail")

        // The items scrub crosses into the grid and steps the highlight; the settle arms the last item.
        demo.drive(pose(2, 0.6), script: .teaching)
        XCTAssertEqual(demo.model.focus, .grid, "the scrub crosses into the grid")
        demo.drive(pose(2, 1.0), script: .teaching)
        XCTAssertGreaterThan(demo.model.selectedIndex, 0, "the scrub steps the highlight across the row")
        XCTAssertTrue(demo.model.arming || demo.model.armed, "the settling dwell arms the highlighted item")

        // And the closing lift fires + hides again.
        demo.drive(pose(2, 1.0, lifted: true), script: .teaching)
        XCTAssertFalse(demo.overlayShown)
    }

    func testDriveFramesAreIdempotent() {
        let demo = seededDemo()
        demo.drive(pose(0, 0.8), script: .teaching)
        demo.drive(pose(1, 0.7), script: .teaching)
        demo.drive(pose(2, 0.6), script: .teaching)
        let band = demo.model.currentBand
        let sel = demo.model.selectedIndex
        demo.drive(pose(2, 0.6), script: .teaching)
        demo.drive(pose(2, 0.65), script: .teaching)
        XCTAssertEqual(demo.model.currentBand, band, "replayed frames don't re-step the band")
        XCTAssertEqual(demo.model.selectedIndex, sel, "replayed frames don't re-step the highlight")
    }

    // MARK: - Band-journey drive (the Clipboard page)

    func testDriveBandJourneyWalksToLastBandAndCloses() {
        let demo = seededDemo(landOnLastBand: true)
        XCTAssertEqual(demo.model.currentBand, 2, "the resting seed shows the page's band (the last)")

        // A full loop: close → reset (hidden) → open → traverse walks the rail to the last band.
        demo.drive(pose(1, 1.0, lifted: true), script: .bandJourney)
        XCTAssertFalse(demo.overlayShown)
        demo.drive(pose(0, 0.2), script: .bandJourney)
        XCTAssertEqual(demo.model.currentBand, 0, "the off-screen reset returns to the home band")
        demo.drive(pose(0, 0.8), script: .bandJourney)
        XCTAssertTrue(demo.overlayShown)
        demo.drive(pose(1, 0.4), script: .bandJourney)
        XCTAssertEqual(demo.model.currentBand, 1, "mid-traverse the walk is partway down the rail")
        demo.drive(pose(1, 1.0), script: .bandJourney)
        XCTAssertEqual(demo.model.currentBand, 2, "the traverse lands on the last band")
        XCTAssertEqual(demo.model.focus, .bands, "the journey stays on the band rail")
        demo.drive(pose(1, 1.0, lifted: true), script: .bandJourney)
        XCTAssertFalse(demo.overlayShown, "the lift closes the loop")
    }

    func testHoverPresentsThePageBandStatically() {
        let demo = seededDemo(landOnLastBand: true)
        // Mid-loop, hidden, partway down the rail…
        demo.drive(pose(1, 1.0, lifted: true), script: .bandJourney)
        demo.drive(pose(0, 0.2), script: .bandJourney)
        XCTAssertFalse(demo.overlayShown)

        // …a hover-demo begins: the panel presents the page's band and holds still.
        demo.drive(pose(0, 0.5, hovering: true), script: .bandJourney)
        XCTAssertTrue(demo.overlayShown, "hovering presents the panel")
        XCTAssertEqual(demo.model.currentBand, 2, "hovering shows the page's own band")
        demo.drive(pose(0, 0.9, hovering: true), script: .bandJourney)
        demo.drive(pose(1, 0.5, hovering: true), script: .bandJourney)
        XCTAssertEqual(demo.model.currentBand, 2, "hover frames never drive the journey")
    }
}
