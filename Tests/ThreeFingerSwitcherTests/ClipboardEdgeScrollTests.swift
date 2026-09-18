import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests the pure edge-auto-repeat acceleration ramp (the interval that shrinks the longer an edge is
/// held). The overflow gate was removed — auto-repeat now applies to all launcher navigation and a
/// step simply clamps (and skips the dwell reset) when there's nowhere to go.
final class ClipboardEdgeScrollTests: XCTestCase {

    // MARK: Acceleration ramp

    func testIntervalAcceleratesWithTicks() {
        let first = LauncherOverlayController.edgeInterval(tick: 0, acceleration: 1.0)
        let later = LauncherOverlayController.edgeInterval(tick: 5, acceleration: 1.0)
        let muchLater = LauncherOverlayController.edgeInterval(tick: 20, acceleration: 1.0)
        XCTAssertGreaterThan(first, later, "the list speeds up the longer the edge is held")
        XCTAssertGreaterThan(later, muchLater)
    }

    func testIntervalIsFloored() {
        let veryLate = LauncherOverlayController.edgeInterval(tick: 10_000, acceleration: 3.0)
        XCTAssertGreaterThanOrEqual(veryLate, 0.03, "interval never drops below the floor")
    }

    func testHigherAccelerationIsFaster() {
        let slow = LauncherOverlayController.edgeInterval(tick: 5, acceleration: 0.5)
        let fast = LauncherOverlayController.edgeInterval(tick: 5, acceleration: 3.0)
        XCTAssertGreaterThan(slow, fast, "higher acceleration yields a shorter interval at the same tick")
    }

    // MARK: Clipboard-only horizontal suppression, decided per tick

    func testHorizontalEdgeStepIsSuppressedOnlyOnTheClipboardBand() {
        XCTAssertEqual(LauncherOverlayController.horizontalEdgeStep(1, isClipboardBand: true), 0)
        XCTAssertEqual(LauncherOverlayController.horizontalEdgeStep(-1, isClipboardBand: true), 0)
        XCTAssertEqual(LauncherOverlayController.horizontalEdgeStep(1, isClipboardBand: false), 1)
        XCTAssertEqual(LauncherOverlayController.horizontalEdgeStep(-1, isClipboardBand: false), -1)
    }

    /// The suppression used to be decided ONCE when the edge was entered, while every tick stepped
    /// unconditionally: a held right edge that scrubbed onto the Clipboard band auto-pinned within two
    /// ticks, and one that scrubbed off it never resumed horizontal repeat. Now each tick re-derives it from
    /// the band the cursor is on, keeping the raw edge direction.
    @MainActor
    func testHeldRightEdgeNeverAutoPinsOnClipboardBandAndResumesOffIt() {
        let controller = LauncherOverlayController()
        let model = controller.model
        let clip = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .text, key: "clip",
                                  representations: [ClipboardUTI.plainText: .inline(Data("clip".utf8))],
                                  fingerprint: "text:clip")
        let clipItem = LaunchItem(id: clip.id, title: clip.key, icon: .sfSymbol("doc"), kind: .clipboardEntry(clip))
        let fav = LaunchItem(title: "Fav", icon: .sfSymbol("star"), kind: .url(URL(string: "https://example.com")!))
        let color = ItemColor(red: 0.5, green: 0.5, blue: 0.5)
        var pinToggles = 0
        model.onPinToggle = { _ in pinToggles += 1 }
        model.clipboardPinStepThreshold = 2
        model.setBands([[fav], [clipItem]], names: ["Fav", "Clipboard"], colors: [color, color],
                       startBand: 1, column: 0, clipboardBandIndex: 1)
        model.stepHorizontal(1)   // into the Clipboard key list
        XCTAssertTrue(model.currentBandIsClipboard)
        XCTAssertEqual(model.focus, .grid)

        // Hold the right edge on the Clipboard band: ticks must not pin (nor move).
        controller.setEdgeAutoScroll(dx: 1, dy: 0)
        for _ in 0..<4 { controller.edgeTick() }
        XCTAssertEqual(pinToggles, 0, "a held edge never auto-pins")
        XCTAssertFalse(model.isPinned(clipItem))
        XCTAssertEqual(model.focus, .grid)
        XCTAssertEqual(model.selectedIndex, 0)

        // Scrub off the Clipboard band with the edge still held (LEFT exits to the band list, UP = the
        // previous band): horizontal repeat resumes at once — the next tick crosses into the Fav grid.
        model.stepHorizontal(-1)
        model.stepVertical(1)
        XCTAssertFalse(model.currentBandIsClipboard)
        XCTAssertEqual(model.focus, .bands)
        controller.edgeTick()
        XCTAssertEqual(model.focus, .grid, "horizontal auto-repeat resumed without re-entering the edge zone")
        XCTAssertEqual(model.selectedItem?.title, "Fav")

        controller.cancel()   // stop the edge timer + any dwell charge
    }
}
