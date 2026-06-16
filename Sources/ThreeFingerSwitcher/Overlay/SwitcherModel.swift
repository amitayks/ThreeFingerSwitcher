import AppKit
import CoreGraphics
import Combine

/// Drives the overlay view. `rows` (Space-rows from `SpaceGrouping`) + `currentRow` select which
/// Space is shown; within that Space the windows are flow-wrapped into a uniform-scale GRID. The
/// grid (`gridLayout.rows`, `currentGridRow`, `col`) is derived from the solved layout; `windows`
/// and `selectedIndex` (the flat index into the current Space's windows) stay published so the
/// existing highlight binding, live-preview "highlighted window," and thumbnail prefetch keep
/// working unchanged.
@MainActor
final class SwitcherModel: ObservableObject {
    /// The result of moving the selection vertically: either it moved within the current Space's grid,
    /// or it hit the grid's top/bottom edge — in which case the caller switches Space by `spaceDelta`.
    enum VerticalMove: Equatable {
        case moved
        case atEdge(spaceDelta: Int)
    }

    // Space dimension (one row per Space, from SpaceGrouping).
    @Published private(set) var rows: [[WindowInfo]] = []
    @Published private(set) var rowLabels: [String] = []   // e.g. Space numbers, one per Space
    @Published private(set) var currentRow: Int = 0
    /// +1 if the last Space change moved to a later Space, -1 earlier (drives the slide direction).
    @Published private(set) var lastRowDirection: Int = 1

    // Current Space's view state.
    @Published var windows: [WindowInfo] = []
    @Published var selectedIndex: Int = 0   // flat index into `windows`
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    /// True when the current Space's grid is taller than the canvas.
    @Published var overflow: Bool = false
    /// Every Space's solved uniform-scale grid (index-aligned to `rows`). The overlay renders ALL
    /// Spaces stacked as one vertical reel, so each Space is solved — not just the current one — and
    /// switching Space animates a single reel offset instead of swapping one view for another.
    @Published private(set) var spaceGrids: [SwitcherGridLayout] = []
    /// True when Space-row switching is opted in but its gesture relocation still awaits the
    /// one-time re-login — the indicator then shows a pending hint instead of a silently dead axis.
    @Published var rowSwitchingPending: Bool = false

    /// The canvas the grid solves into (set by the controller from the screen, or a sensible default
    /// so the onboarding demo renders before any controller sizes it).
    private var canvasSize = CGSize(width: 900, height: 260)
    /// The uniform-scale cap the grid solves to — the configurable "window size" (default `kMax`).
    private var maxScale = SwitcherLayout.kMax

    var rowCount: Int { rows.count }

    /// The current Space's solved grid (drives navigation: visual rows, the selected row/col).
    var gridLayout: SwitcherGridLayout {
        spaceGrids.indices.contains(currentRow) ? spaceGrids[currentRow] : .empty
    }

    /// The largest grid content size across all Spaces — the reel's uniform cell size and the panel's
    /// canvas, so the container fits every Space and stays put while the reel moves between them.
    var maxContentSize: CGSize {
        spaceGrids.reduce(.zero) { acc, g in
            CGSize(width: max(acc.width, g.contentSize.width),
                   height: max(acc.height, g.contentSize.height))
        }
    }

    /// The visual row (within the current Space's grid) the selection currently sits in.
    var currentGridRow: Int { gridLayout.rows.firstIndex { $0.contains(selectedIndex) } ?? 0 }

    /// The column (within its visual row) the selection currently sits at.
    var col: Int {
        guard gridLayout.rows.indices.contains(currentGridRow) else { return 0 }
        return gridLayout.rows[currentGridRow].firstIndex(of: selectedIndex) ?? 0
    }

    func setRows(_ rows: [[WindowInfo]], labels: [String], startRow: Int, column: Int) {
        self.rows = rows
        self.rowLabels = labels
        self.currentRow = clamp(startRow, 0, max(rows.count - 1, 0))
        self.thumbnails = [:]
        thumbsFrozen = false            // a fresh show never inherits a prior slide's freeze…
        pendingThumbnails.removeAll()   // …nor its buffered (now-cleared) frames
        recomputeGrids()
        applyCurrentRow(column: column)
    }

    /// Move to a Space-row (clamped). Resets the selection to the new Space's grid top-left (0,0).
    func setRow(_ row: Int) {
        guard !rows.isEmpty else { return }
        let target = clamp(row, 0, rows.count - 1)
        if target != currentRow { lastRowDirection = target > currentRow ? 1 : -1 }
        currentRow = target
        applyCurrentRow(column: 0)
    }

    func setColumn(_ column: Int) {
        selectedIndex = clamp(column, 0, max(windows.count - 1, 0))
    }

    /// Set the canvas the grid solves into and recompute when it meaningfully changes.
    func setCanvas(_ size: CGSize) {
        guard abs(size.width - canvasSize.width) > 0.5 || abs(size.height - canvasSize.height) > 0.5
        else { return }
        canvasSize = size
        recomputeGrids()
        applyCurrentRow(column: selectedIndex)
    }

    /// Set the uniform-scale cap (the configurable "window size") and recompute when it changes.
    func setMaxScale(_ scale: CGFloat) {
        let clamped = max(scale, SwitcherLayout.kMin)
        guard abs(clamped - maxScale) > 1e-4 else { return }
        maxScale = clamped
        recomputeGrids()
        applyCurrentRow(column: selectedIndex)
    }

    // MARK: - Grid navigation

    /// Horizontal scrub: move the selection WITHIN the current visual row (clamp at the row's ends, or
    /// wrap within the row when `wrap` is set). Never jumps to another row.
    func moveHorizontal(_ direction: Int, wrap: Bool) {
        guard !windows.isEmpty, gridLayout.rows.indices.contains(currentGridRow) else { return }
        let row = gridLayout.rows[currentGridRow]
        guard let pos = row.firstIndex(of: selectedIndex), !row.isEmpty else { return }
        var next = pos + direction
        if wrap {
            next = ((next % row.count) + row.count) % row.count
        } else {
            next = clamp(next, 0, row.count - 1)
        }
        selectedIndex = row[next]
    }

    /// Vertical scrub: move between visual rows, landing on the first (leftmost) card of the adjacent
    /// row. `direction` follows the gesture: +1 = up (toward the top row), -1 = down. At the top row an
    /// up-step (or the bottom row a down-step) reports an edge crossing so the caller switches Space —
    /// up preserves the existing "later Space" direction (+1), down the earlier (-1).
    func moveVertical(_ direction: Int) -> VerticalMove {
        guard !windows.isEmpty, !gridLayout.rows.isEmpty else {
            return .atEdge(spaceDelta: direction > 0 ? 1 : -1)
        }
        let r = currentGridRow
        if direction > 0 {                       // up
            guard r > 0 else { return .atEdge(spaceDelta: 1) }
            selectedIndex = gridLayout.rows[r - 1].first ?? selectedIndex
        } else {                                 // down
            guard r < gridLayout.rows.count - 1 else { return .atEdge(spaceDelta: -1) }
            selectedIndex = gridLayout.rows[r + 1].first ?? selectedIndex
        }
        return .moved
    }

    /// While a Space-switch slide animates, thumbnail updates are BUFFERED rather than published: a
    /// mid-slide `@Published` mutation re-renders the view, re-applies the reel `.offset` non-animated,
    /// and snaps the slide (preview-bearing cards jumping instead of sliding on a Space's first visit).
    /// Buffered frames flush once the slide settles (`flushThumbnails`) and cut in then. Seeded cached
    /// thumbnails applied BEFORE the freeze are already present and slide with the cards.
    private var thumbsFrozen = false
    private var pendingThumbnails: [CGWindowID: NSImage] = [:]

    func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        if thumbsFrozen {
            pendingThumbnails[id] = image
        } else {
            thumbnails[id] = image
        }
    }

    /// Apply a CACHED thumbnail IMMEDIATELY, bypassing the slide freeze. A seed is a known-good cached
    /// image applied inside a switch's own animated tick, so it can't snap the slide (only a live capture
    /// arriving in a LATER, non-animated tick can — that is what the freeze buffers). It must be visible
    /// the instant the Space slides in, even while an EARLIER switch's freeze still holds: during fast,
    /// consecutive Space switches the freeze from the previous switch would otherwise withhold the next
    /// Space's cached previews until it flushes, so they'd appear a beat late.
    func seedThumbnail(_ image: NSImage, for id: CGWindowID) {
        if thumbnails[id] === image { return }   // identical re-seed: don't republish (no needless re-render)
        thumbnails[id] = image
    }

    /// Begin buffering thumbnail updates (held for the slide's duration by the controller).
    func freezeThumbnails() { thumbsFrozen = true }

    /// Stop buffering and apply every buffered frame in one mutation (one re-render) so they cut in
    /// together after the slide. Idempotent — safe to call when nothing is buffered.
    func flushThumbnails() {
        thumbsFrozen = false
        guard !pendingThumbnails.isEmpty else { return }
        thumbnails.merge(pendingThumbnails) { _, new in new }
        pendingThumbnails.removeAll()
    }

    var selectedWindow: WindowInfo? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    /// Window ids in the current Space (for thumbnail prefetch).
    var currentRowIDs: [CGWindowID] { windows.map(\.id) }

    private func applyCurrentRow(column: Int) {
        windows = rows.indices.contains(currentRow) ? rows[currentRow] : []
        overflow = gridLayout.overflowsVertically
        selectedIndex = clamp(column, 0, max(windows.count - 1, 0))
    }

    /// Re-solve the uniform-scale grid for EVERY Space's windows against the canvas (the reel renders
    /// them all). Cheap — a handful of Spaces — and only runs when the rows, canvas, or scale change,
    /// not on a plain Space switch (which just re-picks the current row).
    private func recomputeGrids() {
        spaceGrids = rows.map { spaceWindows in
            let naturals = spaceWindows.map { SwitcherLayout.naturalSize(realFrame: $0.realFrame, frame: $0.frame) }
            return SwitcherLayout.solveGrid(naturals: naturals, canvas: canvasSize, maxScale: maxScale)
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
