import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// The pure Dock-hover brain — hit-testing, orientation-aware anchoring, and the live-zone + grace
/// lifecycle — asserted without a live Dock or AppKit, mirroring how the switcher's ordering/scroll rules
/// are unit-tested. Coordinates are Cocoa global (bottom-left), as the model documents.
@MainActor
final class DockHoverModelTests: XCTestCase {

    private func tile(_ pid: pid_t, _ rect: CGRect) -> DockTile {
        DockTile(pid: pid, bundleID: nil, title: "App\(pid)", frame: rect)
    }

    // MARK: - Hit-test

    func test_hitTest_findsTileUnderCursor() {
        let tiles = [tile(1, CGRect(x: 0, y: 0, width: 50, height: 50)),
                     tile(2, CGRect(x: 60, y: 0, width: 50, height: 50))]
        XCTAssertEqual(DockHoverModel.tile(at: CGPoint(x: 25, y: 25), in: tiles)?.pid, 1)
        XCTAssertEqual(DockHoverModel.tile(at: CGPoint(x: 85, y: 25), in: tiles)?.pid, 2)
        XCTAssertNil(DockHoverModel.tile(at: CGPoint(x: 200, y: 25), in: tiles))
    }

    func test_hitTest_magnifiedTileCoversLargerArea() {
        // Magnification only grows a tile's frame — a point outside the base size now hits.
        let base = tile(1, CGRect(x: 0, y: 0, width: 50, height: 50))
        let magnified = tile(1, CGRect(x: -15, y: 0, width: 80, height: 80))   // maxX 65, maxY 80
        XCTAssertNil(DockHoverModel.tile(at: CGPoint(x: 60, y: 60), in: [base]))        // outside base 50×50
        XCTAssertEqual(DockHoverModel.tile(at: CGPoint(x: 60, y: 60), in: [magnified])?.pid, 1)
    }

    func test_isInStrip_usesPaddedUnion() {
        let tiles = [tile(1, CGRect(x: 0, y: 0, width: 50, height: 50)),
                     tile(2, CGRect(x: 200, y: 0, width: 50, height: 50))]
        XCTAssertTrue(DockHoverModel.isInStrip(CGPoint(x: 125, y: 25), tiles: tiles))   // gap, within union
        XCTAssertTrue(DockHoverModel.isInStrip(CGPoint(x: -10, y: 25), tiles: tiles))   // within pad
        XCTAssertFalse(DockHoverModel.isInStrip(CGPoint(x: 125, y: 400), tiles: tiles)) // far above
        XCTAssertFalse(DockHoverModel.isInStrip(CGPoint(x: 0, y: 0), tiles: []))        // no tiles
    }

    // MARK: - Anchor placement (orientation)

    func test_anchor_bottomDock_isAboveTileAndCentered() {
        let t = CGRect(x: 100, y: 0, width: 60, height: 60)               // tile at the bottom
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let r = DockHoverModel.anchorRect(for: t, orientation: .bottom,
                                          popupSize: CGSize(width: 200, height: 180), screenFrame: screen)
        XCTAssertEqual(r.midX, t.midX, accuracy: 0.5)                     // centered on the tile
        XCTAssertEqual(r.minY, t.maxY + DockHoverModel.anchorGap, accuracy: 0.5)  // above (larger y)
    }

    func test_anchor_leftDock_isRightOfTile() {
        let t = CGRect(x: 0, y: 400, width: 60, height: 60)              // tile on the left edge
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let r = DockHoverModel.anchorRect(for: t, orientation: .left,
                                          popupSize: CGSize(width: 200, height: 180), screenFrame: screen)
        XCTAssertEqual(r.minX, t.maxX + DockHoverModel.anchorGap, accuracy: 0.5)  // to the right
        XCTAssertEqual(r.midY, t.midY, accuracy: 0.5)                    // centered vertically
    }

    func test_anchor_rightDock_isLeftOfTile() {
        let t = CGRect(x: 1380, y: 400, width: 60, height: 60)          // tile on the right edge
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let r = DockHoverModel.anchorRect(for: t, orientation: .right,
                                          popupSize: CGSize(width: 200, height: 180), screenFrame: screen)
        XCTAssertEqual(r.maxX, t.minX - DockHoverModel.anchorGap, accuracy: 0.5)  // to the left
        XCTAssertEqual(r.midY, t.midY, accuracy: 0.5)
    }

    func test_anchor_clampsWithinScreen() {
        let t = CGRect(x: 0, y: 0, width: 60, height: 60)               // hard against the corner
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let r = DockHoverModel.anchorRect(for: t, orientation: .bottom,
                                          popupSize: CGSize(width: 400, height: 180), screenFrame: screen)
        XCTAssertGreaterThanOrEqual(r.minX, screen.minX)               // not off the left edge
        XCTAssertLessThanOrEqual(r.maxX, screen.maxX)                  // not off the right edge
    }

    // MARK: - Lifecycle: open / swap / live-zone / grace dismiss

    private let tilesFixture = [
        DockTile(pid: 1, bundleID: nil, title: "A", frame: CGRect(x: 0, y: 0, width: 50, height: 50)),
        DockTile(pid: 2, bundleID: nil, title: "B", frame: CGRect(x: 60, y: 0, width: 50, height: 50))
    ]

    func test_lifecycle_opensOnTileHover() {
        let m = DockHoverModel()
        let d = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: nil, now: 0)
        XCTAssertEqual(d, .open(pid: 1))
        XCTAssertEqual(m.state, .active(pid: 1))
    }

    func test_lifecycle_idleWhenNothingHovered() {
        let m = DockHoverModel()
        XCTAssertEqual(m.feed(cursor: CGPoint(x: 500, y: 500), tiles: tilesFixture, popupFrame: nil, now: 0), .idle)
    }

    func test_lifecycle_cursorTravelsIntoPopupKeepsOpen() {
        let m = DockHoverModel()
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: nil, now: 0)
        let popup = CGRect(x: 0, y: 58, width: 200, height: 180)
        // Cursor left the tile but is over the popup → stays open, no grace.
        let d = m.feed(cursor: CGPoint(x: 100, y: 120), tiles: tilesFixture, popupFrame: popup, now: 1)
        XCTAssertEqual(d, .open(pid: 1))
    }

    func test_lifecycle_movingToOtherTileSwaps() {
        let m = DockHoverModel()
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: nil, now: 0)
        let d = m.feed(cursor: CGPoint(x: 85, y: 25), tiles: tilesFixture, popupFrame: nil, now: 1)
        XCTAssertEqual(d, .open(pid: 2))
        XCTAssertEqual(m.state, .active(pid: 2))
    }

    func test_lifecycle_leavingZoneDismissesAfterGrace() {
        let m = DockHoverModel(graceInterval: 0.25)
        let popup = CGRect(x: 0, y: 58, width: 200, height: 180)
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: popup, now: 0)
        // Leave both tile and popup at t=0.10 → grace deadline 0.35: still open at 0.30, dismiss at 0.40.
        let out = CGPoint(x: 800, y: 800)
        XCTAssertEqual(m.feed(cursor: out, tiles: tilesFixture, popupFrame: popup, now: 0.10), .open(pid: 1))
        XCTAssertEqual(m.feed(cursor: out, tiles: tilesFixture, popupFrame: popup, now: 0.30), .open(pid: 1))
        XCTAssertEqual(m.feed(cursor: out, tiles: tilesFixture, popupFrame: popup, now: 0.40), .dismiss)
        XCTAssertEqual(m.state, .idle)
    }

    func test_lifecycle_reenteringZoneCancelsGrace() {
        let m = DockHoverModel(graceInterval: 0.25)
        let popup = CGRect(x: 0, y: 58, width: 200, height: 180)
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: popup, now: 0)
        _ = m.feed(cursor: CGPoint(x: 800, y: 800), tiles: tilesFixture, popupFrame: popup, now: 0.10) // grace armed
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: popup, now: 0.15)   // back on tile
        // Grace must have been cleared: a later sample past the OLD deadline still stays open.
        XCTAssertEqual(m.feed(cursor: CGPoint(x: 100, y: 120), tiles: tilesFixture, popupFrame: popup, now: 0.40), .open(pid: 1))
    }

    // MARK: - Right-click yields to the native menu

    func test_rightClick_overTileWhileOpen_dismisses() {
        let m = DockHoverModel()
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: nil, now: 0)  // open on tile 1
        XCTAssertEqual(m.rightClick(at: CGPoint(x: 25, y: 25), tiles: tilesFixture), .dismiss)
        XCTAssertEqual(m.state, .idle)
    }

    func test_rightClick_overAnotherTileWhileOpen_dismisses() {
        // Right-clicking a different app's tile (its native menu is opening) also yields the popup.
        let m = DockHoverModel()
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: nil, now: 0)  // open on tile 1
        XCTAssertEqual(m.rightClick(at: CGPoint(x: 85, y: 25), tiles: tilesFixture), .dismiss)    // tile 2
    }

    func test_rightClick_offAnyTile_isNoOp() {
        let m = DockHoverModel()
        _ = m.feed(cursor: CGPoint(x: 25, y: 25), tiles: tilesFixture, popupFrame: nil, now: 0)
        // A right-click on the popup / empty space is not the tile menu → the popup stays open.
        XCTAssertEqual(m.rightClick(at: CGPoint(x: 500, y: 500), tiles: tilesFixture), .idle)
        XCTAssertEqual(m.state, .active(pid: 1))
    }

    func test_rightClick_onTileWhenNothingOpen_actsToSuppress() {
        // Even with no popup open, a right-click on a tile signals dismiss/suppress, so the popup can't
        // pop up behind the just-opened native menu on the next cursor move.
        let m = DockHoverModel()
        XCTAssertEqual(m.rightClick(at: CGPoint(x: 25, y: 25), tiles: tilesFixture), .dismiss)
        XCTAssertEqual(m.state, .idle)
    }
}
