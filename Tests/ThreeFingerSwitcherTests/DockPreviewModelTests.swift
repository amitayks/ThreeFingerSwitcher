import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// The Dock-preview row model and the minimized-inclusive ordering: empty-app suppression, minimized
/// flagging, and stable identity across re-lists. The live AX/CGS enumeration in `WindowService` is not
/// unit-testable here (no AX seam) and is covered by manual verification; what IS pure — the ordering and
/// the `WindowInfo.isMinimized` flag that leaves the switcher path untouched — is asserted directly.
@MainActor
final class DockPreviewModelTests: XCTestCase {

    private func win(_ id: CGWindowID, title: String = "W", minimized: Bool = false) -> DockPreviewWindow {
        DockPreviewWindow(id: id, title: title, isMinimized: minimized, aspect: 1.6)
    }

    func test_hasContent_falseWhenEmpty() {
        let m = DockPreviewModel()
        XCTAssertFalse(m.hasContent)                                   // no popup for an empty app
        m.setWindows([win(1)], appName: "A", icons: [:])
        XCTAssertTrue(m.hasContent)
    }

    func test_minimizedFlagFlowsThrough() {
        let m = DockPreviewModel()
        m.setWindows([win(1), win(2, minimized: true)], appName: "A", icons: [:])
        XCTAssertEqual(m.windows.first(where: { $0.id == 2 })?.isMinimized, true)
        XCTAssertEqual(m.windows.first(where: { $0.id == 1 })?.isMinimized, false)
    }

    func test_relist_preservesHighlightWhenStillPresent() {
        let m = DockPreviewModel()
        m.setWindows([win(1), win(2)], appName: "A", icons: [:])
        m.highlightedID = 2
        m.setWindows([win(1), win(2), win(3)], appName: "A", icons: [:])   // re-list, 2 still present
        XCTAssertEqual(m.highlightedID, 2)                                  // stable, no strobe
    }

    func test_relist_clearsHighlightWhenWindowGone() {
        let m = DockPreviewModel()
        m.setWindows([win(1), win(2)], appName: "A", icons: [:])
        m.highlightedID = 2
        m.setWindows([win(1)], appName: "A", icons: [:])                    // window 2 closed
        XCTAssertNil(m.highlightedID)
    }

    func test_relist_dropsThumbnailsForGoneWindows() {
        let m = DockPreviewModel()
        m.setWindows([win(1), win(2)], appName: "A", icons: [:])
        m.setThumbnail(NSImage(), for: 2)
        XCTAssertNotNil(m.thumbnails[2])
        m.setWindows([win(1)], appName: "A", icons: [:])
        XCTAssertNil(m.thumbnails[2])                                       // bounded to the live row
    }

    func test_setThumbnail_ignoresWindowsNotInRow() {
        let m = DockPreviewModel()
        m.setWindows([win(1)], appName: "A", icons: [:])
        m.setThumbnail(NSImage(), for: 99)
        XCTAssertNil(m.thumbnails[99])
    }

    func test_clear_resetsEverything() {
        let m = DockPreviewModel()
        m.setWindows([win(1)], appName: "A", icons: [:])
        m.highlightedID = 1
        m.setError(.windowUnavailable(name: "W"))
        m.clear()
        XCTAssertFalse(m.hasContent)
        XCTAssertNil(m.highlightedID)
        XCTAssertNil(m.error)
    }

    // MARK: - Ordering + switcher-unaffected (3.3)

    private func info(_ id: CGWindowID, minimized: Bool) -> WindowInfo {
        WindowInfo(id: id, pid: 1, appName: "A", title: "W\(id)", appIcon: nil,
                   frame: .zero, axElement: nil, isOnCurrentSpace: true, spaceID: nil,
                   spaceIndex: 0, isMinimized: minimized)
    }

    func test_dockPreviewOrder_nonMinimizedFirstThenStableID() {
        let ordered = WindowService.dockPreviewOrder([
            info(3, minimized: true),
            info(1, minimized: false),
            info(4, minimized: true),
            info(2, minimized: false)
        ])
        XCTAssertEqual(ordered.map(\.id), [1, 2, 3, 4])                     // live first, then ids ascending
        XCTAssertEqual(ordered.map(\.isMinimized), [false, false, true, true])
    }

    // MARK: - Aspect-driven tab sizing

    func test_cardWidth_scalesWithAspectAndClamps() {
        let h = DockPreviewLayout.thumbHeight
        // A normal 16:10 window: height × aspect, within the clamp range.
        XCTAssertEqual(DockPreviewLayout.cardWidth(forAspect: 1.6), min(max(h * 1.6, DockPreviewLayout.minCardWidth), DockPreviewLayout.maxCardWidth), accuracy: 0.5)
        // A very portrait window clamps up to the floor (not a sliver).
        XCTAssertEqual(DockPreviewLayout.cardWidth(forAspect: 0.2), DockPreviewLayout.minCardWidth, accuracy: 0.5)
        // An ultrawide window clamps to the ceiling.
        XCTAssertEqual(DockPreviewLayout.cardWidth(forAspect: 5.0), DockPreviewLayout.maxCardWidth, accuracy: 0.5)
        // A garbage aspect falls back to 16:10, not NaN.
        XCTAssertEqual(DockPreviewLayout.cardWidth(forAspect: 0), DockPreviewLayout.cardWidth(forAspect: 1.6), accuracy: 0.5)
    }

    func test_popupSize_sumsAspectWidthsAndClampsToScreen() {
        let wide = DockPreviewLayout.size(forAspects: [1.6, 1.6, 1.6], maxWidth: 4000)
        // Three cards + spacing + padding, all within the wide screen.
        let expected = DockPreviewLayout.padding * 2
            + DockPreviewLayout.cardWidth(forAspect: 1.6) * 3
            + DockPreviewLayout.cardSpacing * 2
        XCTAssertEqual(wide.width, expected, accuracy: 0.5)
        XCTAssertEqual(wide.height, DockPreviewLayout.height, accuracy: 0.5)
        // Many cards clamp to the available screen width (the row then scrolls).
        let clamped = DockPreviewLayout.size(forAspects: Array(repeating: 1.6, count: 50), maxWidth: 800)
        XCTAssertEqual(clamped.width, 800, accuracy: 0.5)
    }

    func test_windowInfo_defaultsToNotMinimized() {
        // The switcher's snapshot path constructs WindowInfo WITHOUT the flag — it must default false so
        // the switcher (which excludes minimized) is unaffected by the new field.
        let w = WindowInfo(id: 7, pid: 1, appName: "A", title: "W", appIcon: nil,
                           frame: .zero, axElement: nil, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
        XCTAssertFalse(w.isMinimized)
    }
}
