import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests the Clipboard band's repurposed navigation in `LauncherModel`: vertical scrubs entries,
/// a RIGHT step pins the selected entry without moving the selection, and a LEFT step leaves to the
/// previous band.
@MainActor
final class ClipboardNavigationTests: XCTestCase {

    private func entry(_ text: String, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .text,
                       key: text, pinned: pinned,
                       representations: [ClipboardUTI.plainText: .inline(Data(text.utf8))],
                       fingerprint: "text:\(text)")
    }

    /// A model with one normal band and a Clipboard band (last), entered on the Clipboard band.
    private func makeModel(clipCount: Int = 3) -> (LauncherModel, [ClipboardEntry]) {
        let entries = (0..<clipCount).map { entry("clip\($0)") }
        let clipItems = entries.map { LaunchItem(id: $0.id, title: $0.key, icon: .sfSymbol("doc"),
                                                 kind: .clipboardEntry($0)) }
        let favItems = [LaunchItem(title: "Fav", icon: .sfSymbol("star"),
                                   kind: .url(URL(string: "https://example.com")!))]
        let color = ItemColor(red: 0.5, green: 0.5, blue: 0.5)
        let model = LauncherModel()
        model.setBands([favItems, clipItems], names: ["Fav", "Clipboard"], colors: [color, color],
                       startBand: 1, column: 0, clipboardBandIndex: 1)
        return (model, entries)
    }

    func testEntersClipboardBandInGridFocus() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.currentBandIsClipboard)
        XCTAssertEqual(model.focus, .grid)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testVerticalScrubsEntries() {
        let (model, _) = makeModel(clipCount: 3)
        model.stepVertical(-1)   // down the list
        XCTAssertEqual(model.selectedIndex, 1)
        model.stepVertical(-1)
        XCTAssertEqual(model.selectedIndex, 2)
        model.stepVertical(1)    // up
        XCTAssertEqual(model.selectedIndex, 1)
    }

    func testVerticalUpAtTopRisesToHeaders() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.selectedIndex, 0)
        model.stepVertical(1)    // up from the first row → headers
        XCTAssertEqual(model.focus, .headers)
    }

    func testSmallHorizontalStepDoesNotPin() {
        let (model, _) = makeModel()
        model.clipboardPinStepThreshold = 3
        var toggled = 0
        model.onPinToggle = { _ in toggled += 1 }
        model.stepHorizontal(1)   // one fine step — below threshold
        model.stepHorizontal(1)   // two — still below
        XCTAssertEqual(toggled, 0, "a small horizontal movement must not pin")
        XCTAssertFalse(model.isPinned(model.selectedItem!))
    }

    func testDeliberateRightFlickPinsOnceWithoutMoving() {
        let (model, entries) = makeModel()
        model.clipboardPinStepThreshold = 3
        var toggled: [UUID] = []
        model.onPinToggle = { toggled.append($0.id) }

        for _ in 0..<5 { model.stepHorizontal(1) }   // a long right flick: crosses threshold then keeps going

        XCTAssertEqual(toggled, [entries[0].id], "one flick pins exactly once (latched while held)")
        XCTAssertEqual(model.selectedIndex, 0, "selection does not move when pinning")
        XCTAssertTrue(model.isPinned(model.selectedItem!), "visual pin marker is set")
    }

    func testReturnToCentreAllowsAnotherPin() {
        let (model, _) = makeModel()
        model.clipboardPinStepThreshold = 2
        var toggled = 0
        model.onPinToggle = { _ in toggled += 1 }

        model.stepHorizontal(1); model.stepHorizontal(1)    // flick right → pin
        XCTAssertEqual(toggled, 1)
        model.stepHorizontal(-1); model.stepHorizontal(-1)  // return to centre → unlatch, no action
        XCTAssertEqual(toggled, 1, "returning to centre does not itself act")
        model.stepHorizontal(1); model.stepHorizontal(1)    // flick right again → unpin
        XCTAssertEqual(toggled, 2)
        XCTAssertFalse(model.isPinned(model.selectedItem!), "two deliberate flicks return to unpinned")
    }

    func testDeliberateLeftFlickLeavesToPreviousBand() {
        let (model, _) = makeModel()
        model.clipboardPinStepThreshold = 3
        for _ in 0..<3 { model.stepHorizontal(-1) }   // LEFT flick → previous band
        XCTAssertEqual(model.currentBand, 0)
        XCTAssertFalse(model.currentBandIsClipboard)
        XCTAssertEqual(model.focus, .grid)
    }

    func testVerticalDoesNotPin() {
        let (model, _) = makeModel()
        var toggled = 0
        model.onPinToggle = { _ in toggled += 1 }
        model.stepVertical(-1)
        model.stepVertical(1)
        XCTAssertEqual(toggled, 0, "vertical scrubbing never pins")
    }

    func testNormalBandHorizontalStillStepsItems() {
        // Regression: a normal multi-item band still moves the cursor horizontally.
        let items = (0..<3).map { LaunchItem(title: "i\($0)", icon: .sfSymbol("a"),
                                             kind: .url(URL(string: "https://e\($0).com")!)) }
        let color = ItemColor(red: 0.5, green: 0.5, blue: 0.5)
        let model = LauncherModel()
        model.setBands([items], names: ["Fav"], colors: [color], startBand: 0, column: 0,
                       clipboardBandIndex: nil)
        model.stepHorizontal(1)
        XCTAssertEqual(model.selectedIndex, 1)
    }
}
