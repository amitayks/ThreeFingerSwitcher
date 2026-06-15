import Foundation
import CoreGraphics

/// The pure, synchronous brain of Dock-hover detection: hit-testing the cursor against tile frames,
/// computing where the popup anchors for each Dock orientation, and the open/swap/keep/dismiss
/// lifecycle with a unified tile+popup "live zone" and a grace-period dismiss.
///
/// It owns NO AppKit, NO timers, and NO capture — the controller feeds it cursor points, the current
/// tiles, the open popup's frame, and a timestamp, and acts on the returned `Decision`. Keeping time an
/// *input* (not a read of the clock) makes every transition deterministically testable. (Coordinates are
/// Cocoa global, bottom-left — see `DockTile`.)
@MainActor
final class DockHoverModel {
    /// Gap between the hovered tile and the popup, and the popup's inset from the screen edge.
    static let anchorGap: CGFloat = 8
    static let screenInset: CGFloat = 8

    /// How long the cursor may sit outside the live zone before the popup dismisses. Bridges the gap as
    /// the cursor travels from tile to popup (or briefly slips off an edge) without a flicker.
    let graceInterval: TimeInterval

    enum State: Equatable {
        case idle
        /// The popup is (or should be) open for this app's tile.
        case active(pid: pid_t)
    }

    /// What the controller should do after a `feed`.
    enum Decision: Equatable {
        /// Nothing open; ensure the popup is closed.
        case idle
        /// Open (or keep) the popup for `pid`. A change of `pid` from the prior decision is a swap.
        case open(pid: pid_t)
        /// Close the popup (grace elapsed after leaving the live zone).
        case dismiss
    }

    private(set) var state: State = .idle
    /// Deadline after which a left-zone popup dismisses; nil while inside the zone.
    private var graceDeadline: TimeInterval?

    init(graceInterval: TimeInterval = 0.25) {
        self.graceInterval = graceInterval
    }

    /// Advance the lifecycle for a cursor sample.
    /// - Parameters:
    ///   - cursor: cursor position (Cocoa global).
    ///   - tiles: the current Dock app tiles.
    ///   - popupFrame: the open popup's frame, or nil when no popup is showing.
    ///   - now: a monotonic timestamp (seconds); injected so grace timing is testable.
    func feed(cursor: CGPoint, tiles: [DockTile], popupFrame: CGRect?, now: TimeInterval) -> Decision {
        // 1. Cursor directly over an app tile → open/keep/swap to that app and clear any grace.
        if let tile = Self.tile(at: cursor, in: tiles) {
            graceDeadline = nil
            state = .active(pid: tile.pid)
            return .open(pid: tile.pid)
        }

        // 2. Cursor over the open popup (the rest of the live zone) → keep it open for the current app.
        if case let .active(pid) = state, let popupFrame, popupFrame.contains(cursor) {
            graceDeadline = nil
            return .open(pid: pid)
        }

        // 3. Outside the live zone.
        guard case let .active(pid) = state else {
            return .idle
        }
        // Start the grace clock on first exit; dismiss once it elapses, otherwise keep showing.
        let deadline = graceDeadline ?? (now + graceInterval)
        graceDeadline = deadline
        if now >= deadline {
            state = .idle
            graceDeadline = nil
            return .dismiss
        }
        return .open(pid: pid)
    }

    /// Force back to idle (e.g. the feature was disabled, or the user committed a window).
    func reset() {
        state = .idle
        graceDeadline = nil
    }

    // MARK: - Pure geometry

    /// The app tile whose frame contains `cursor`, or nil. Magnification only grows a tile's frame, so a
    /// magnified tile naturally hit-tests over a larger area with no special-casing.
    static func tile(at cursor: CGPoint, in tiles: [DockTile]) -> DockTile? {
        tiles.first { $0.frame.contains(cursor) }
    }

    /// True when the cursor is within the Dock strip — the union of all tile frames, padded — used by
    /// the controller to gate cheap idle tracking vs. hot per-frame AX re-reads. Empty tiles → false.
    static func isInStrip(_ cursor: CGPoint, tiles: [DockTile], pad: CGFloat = 24) -> Bool {
        guard let first = tiles.first else { return false }
        var union = first.frame
        for t in tiles.dropFirst() { union = union.union(t.frame) }
        return union.insetBy(dx: -pad, dy: -pad).contains(cursor)
    }

    /// Where the popup of size `popupSize` anchors for a hovered `tile`, given the Dock `orientation` and
    /// the Dock screen's usable `screenFrame` — placed just off the tile toward the screen interior and
    /// clamped to stay on screen. Pure, so the placement is unit-testable for every orientation.
    static func anchorRect(for tile: CGRect,
                           orientation: DockOrientation,
                           popupSize: CGSize,
                           screenFrame: CGRect) -> CGRect {
        var origin = CGPoint.zero
        switch orientation {
        case .bottom:
            // Above the tile (Cocoa: toward larger y), centered on the tile horizontally.
            origin.x = tile.midX - popupSize.width / 2
            origin.y = tile.maxY + anchorGap
        case .left:
            // To the right of the tile, centered vertically.
            origin.x = tile.maxX + anchorGap
            origin.y = tile.midY - popupSize.height / 2
        case .right:
            // To the left of the tile, centered vertically.
            origin.x = tile.minX - anchorGap - popupSize.width
            origin.y = tile.midY - popupSize.height / 2
        }
        return clamp(CGRect(origin: origin, size: popupSize), within: screenFrame)
    }

    /// Keep `rect` inside `bounds` (inset by `screenInset`) without resizing it — shift the origin only.
    static func clamp(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return rect }
        let area = bounds.insetBy(dx: screenInset, dy: screenInset)
        var origin = rect.origin
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - rect.width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }
}
