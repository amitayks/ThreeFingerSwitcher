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

    /// Sticky preferred-x anchor for vertical navigation, in CENTER-RELATIVE grid coordinates
    /// (0 = the grid's horizontal center — the one x that is stable across rows of differing width
    /// and across Spaces, since every Space's grid centers in the same reel cell). Captured from the
    /// selected card's x-center when a run of vertical steps begins and reused for every vertical
    /// step in the run, so travelling several rows holds a straight line instead of drifting through
    /// narrow cards. Cleared by any horizontal/linear selection change and by a fresh show.
    private var preferredX: CGFloat?

    /// Validated window groups (the window-groups capability): sets of window ids that render as fused
    /// clusters and raise together. Passed in at `setRows` (the coordinator validates against the live
    /// snapshot); empty means every window is its own layout unit — the pre-groups layout exactly.
    private var groups: [Set<CGWindowID>] = []

    func setRows(_ rows: [[WindowInfo]], labels: [String], startRow: Int, column: Int,
                 groups: [Set<CGWindowID>] = []) {
        self.rows = rows
        self.rowLabels = labels
        self.groups = groups
        self.currentRow = clamp(startRow, 0, max(rows.count - 1, 0))
        self.thumbnails = [:]
        thumbsFrozen = false            // a fresh show never inherits a prior slide's freeze…
        pendingThumbnails.removeAll()   // …nor its buffered (now-cleared) frames
        preferredX = nil
        recomputeGrids()
        applyCurrentRow(column: column)
    }

    /// Move to a Space-row (clamped). Resets the selection to the new Space's grid top-left (0,0).
    func setRow(_ row: Int) {
        guard !rows.isEmpty else { return }
        let target = clamp(row, 0, rows.count - 1)
        if target != currentRow { lastRowDirection = target > currentRow ? 1 : -1 }
        currentRow = target
        preferredX = nil
        applyCurrentRow(column: 0)
    }

    func setColumn(_ column: Int) {
        preferredX = nil
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
    /// wrap within the row when `wrap` is set). Never jumps to another row. Any horizontal intent ends
    /// the current vertical run — the next vertical step re-anchors from the new selection.
    func moveHorizontal(_ direction: Int, wrap: Bool) {
        preferredX = nil
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

    /// Vertical scrub: move between visual rows, landing POSITIONALLY — on the card of the adjacent
    /// row whose horizontal span is nearest the sticky preferred-x anchor (captured from the selected
    /// card's x-center when the run of vertical steps begins). `direction` follows the gesture:
    /// +1 = up (toward the top row), -1 = down. At the top row an up-step (or the bottom row a
    /// down-step) reports an edge crossing so the caller switches Space — up preserves the existing
    /// "later Space" direction (+1), down the earlier (-1).
    func moveVertical(_ direction: Int) -> VerticalMove {
        guard !windows.isEmpty, !gridLayout.rows.isEmpty else {
            return .atEdge(spaceDelta: direction > 0 ? 1 : -1)
        }
        let r = currentGridRow
        let target = direction > 0 ? r - 1 : r + 1
        guard gridLayout.rows.indices.contains(target) else {
            return .atEdge(spaceDelta: direction > 0 ? 1 : -1)
        }
        let anchor = verticalAnchor()
        if let landing = positionalLanding(inGridRow: target, of: gridLayout, anchor: anchor) {
            selectedIndex = landing
        }
        return .moved
    }

    /// The window a vertical step lands on in `gridRow` of `layout` for the given anchor — via the
    /// unit-aware spans, so a fused cluster's members are individually targetable.
    private func positionalLanding(inGridRow gridRow: Int, of layout: SwitcherGridLayout, anchor: CGFloat) -> Int? {
        guard layout.unitRows.indices.contains(gridRow) else { return nil }
        let spans = SwitcherLayout.windowSpans(unitRow: layout.unitRows[gridRow], units: layout.units)
        guard !spans.isEmpty else { return nil }
        let pos = SwitcherLayout.nearestSpan(toAnchorX: anchor, spans: spans.map(\.span))
        return spans.indices.contains(pos) ? spans[pos].index : nil
    }

    /// The anchor for a vertical step: the sticky preferred-x while a run is in progress, else the
    /// selected card's center-relative x-center — captured as the run's new anchor.
    private func verticalAnchor() -> CGFloat {
        if let preferredX { return preferredX }
        var x: CGFloat = 0
        if gridLayout.unitRows.indices.contains(currentGridRow) {
            let spans = SwitcherLayout.windowSpans(
                unitRow: gridLayout.unitRows[currentGridRow], units: gridLayout.units
            )
            if let span = spans.first(where: { $0.index == selectedIndex })?.span {
                x = SwitcherLayout.centerX(of: span)
            }
        }
        preferredX = x
        return x
    }

    /// Switch Space from a vertical grid-edge crossing, landing POSITIONALLY instead of resetting to
    /// the first window: entering `upward` (an up-scrub to the next Space) lands in the new grid's
    /// BOTTOM visual row, entering downward in its TOP visual row — spatially continuous with the
    /// reel's vertical stacking — in both cases on the card nearest the sticky anchor (which is
    /// center-relative, so it carries across Spaces of differing grid width). The anchor survives the
    /// crossing: a run of vertical steps holds its line across Spaces.
    func setRowEntering(_ row: Int, upward: Bool) {
        guard !rows.isEmpty else { return }
        let anchor = verticalAnchor()   // capture from the OLD grid before the swap
        let target = clamp(row, 0, rows.count - 1)
        if target != currentRow { lastRowDirection = target > currentRow ? 1 : -1 }
        currentRow = target
        windows = rows.indices.contains(currentRow) ? rows[currentRow] : []
        overflow = gridLayout.overflowsVertically
        let entryGridRow = upward ? gridLayout.unitRows.count - 1 : 0
        selectedIndex = positionalLanding(inGridRow: entryGridRow, of: gridLayout, anchor: anchor) ?? 0
    }

    // MARK: - Linear traversal (⌘-Tab keyboard driver)

    /// Total windows across every Space-row — the length of the flat reel order.
    var flatCount: Int { rows.reduce(0) { $0 + $1.count } }

    /// Flat index of (row, index) in the reel order: rows concatenated in Mission-Control order, each
    /// row's windows in snapshot order.
    private func flatIndex(row: Int, index: Int) -> Int {
        rows.prefix(row).reduce(0) { $0 + $1.count } + index
    }

    /// Map a flat reel index back to (row, indexInRow), clamped into range.
    private func rowAndIndex(forFlat flat: Int) -> (row: Int, index: Int) {
        guard flatCount > 0 else { return (0, 0) }
        var remaining = clamp(flat, 0, flatCount - 1)
        for (r, spaceWindows) in rows.enumerated() {
            if remaining < spaceWindows.count { return (r, remaining) }
            remaining -= spaceWindows.count
        }
        let lastRow = max(rows.count - 1, 0)                 // defensive (clamped above)
        return (lastRow, max((rows.last?.count ?? 1) - 1, 0))
    }

    /// Pure: the (row, index) that stepping the selection by `delta` along the flat reel order lands on,
    /// wrapping or clamping at the ends per `wrap`. Crossing a Space edge forward lands on the next
    /// Space's first window; a backward wrap lands on the previous row's last window. `nil` when empty.
    func linearTarget(delta: Int, wrap: Bool) -> (row: Int, index: Int)? {
        guard flatCount > 0 else { return nil }
        let cur = flatIndex(row: currentRow, index: selectedIndex)
        var next = cur + delta
        if wrap {
            next = ((next % flatCount) + flatCount) % flatCount
        } else {
            next = clamp(next, 0, flatCount - 1)
        }
        return rowAndIndex(forFlat: next)
    }

    /// Move the selection to a specific Space-row AND column together (unlike `setRow`, which resets the
    /// column to 0). The caller wraps this in `withAnimation` to slide the reel when the row changes; a
    /// bare call lands instantly (matching a (re)show).
    func setRowAndColumn(_ row: Int, column: Int) {
        guard !rows.isEmpty else { return }
        let target = clamp(row, 0, rows.count - 1)
        if target != currentRow { lastRowDirection = target > currentRow ? 1 : -1 }
        currentRow = target
        preferredX = nil   // a linear (reel-order) jump ends any vertical run
        applyCurrentRow(column: column)
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
            SwitcherLayout.solveGrid(units: layoutUnits(for: spaceWindows),
                                     canvas: canvasSize, maxScale: maxScale)
        }
    }

    /// Build one Space's flow-wrap units: each validated group whose members (≥2) are in THIS Space
    /// becomes a fused cluster (members at their real relative frames); every other window is its own
    /// singleton. Units are ordered by their earliest member's snapshot position, so a cluster sits
    /// where its most-recent window would.
    private func layoutUnits(for spaceWindows: [WindowInfo]) -> [SwitcherLayoutUnit] {
        var entries: [(flowPosition: Int, unit: SwitcherLayoutUnit)] = []
        var clustered: Set<Int> = []
        if !groups.isEmpty {
            let indexByID = Dictionary(spaceWindows.enumerated().map { ($1.id, $0) }) { first, _ in first }
            for group in groups {
                let memberIndices = group.compactMap { indexByID[$0] }.sorted()
                guard memberIndices.count >= 2 else { continue }
                let members = memberIndices.map { (index: $0, natural: naturalRect(spaceWindows[$0])) }
                entries.append((memberIndices[0], .cluster(members: members)))
                clustered.formUnion(memberIndices)
            }
        }
        for (i, w) in spaceWindows.enumerated() where !clustered.contains(i) {
            entries.append((i, .single(i, natural: SwitcherLayout.naturalSize(realFrame: w.realFrame, frame: w.frame))))
        }
        return entries.sorted { $0.flowPosition < $1.flowPosition }.map(\.unit)
    }

    /// A cluster member's POSITIONED natural frame (the cluster mirrors real arrangement, so origin
    /// matters — unlike the singleton path, which only needs a size). Real AX frame first, then the
    /// displayed frame, then the default proportion at the origin (degenerate but safe).
    private func naturalRect(_ w: WindowInfo) -> CGRect {
        if w.realFrame.width > 1, w.realFrame.height > 1 { return w.realFrame }
        if w.frame.width > 1, w.frame.height > 1 { return w.frame }
        return CGRect(origin: .zero, size: SwitcherLayout.defaultNaturalSize)
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
