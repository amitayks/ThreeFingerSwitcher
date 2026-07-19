import CoreGraphics

/// One flow-wrap unit BEFORE the solve: a single window, or a fused **cluster** of grouped windows
/// (the window-groups capability) whose members keep their real relative arrangement. Natural
/// (unscaled) geometry, all frames relative to the unit's own top-left origin.
struct SwitcherLayoutUnit: Equatable {
    /// Window indices in visual order (left-to-right, then top-to-bottom of the real arrangement).
    let members: [Int]
    /// Each member's natural frame within the unit (index-aligned to `members`). A singleton has one
    /// zero-origin frame equal to its natural size.
    let memberFrames: [CGRect]
    /// The unit's natural size: the singleton's natural size, or the members' union-rect size.
    let naturalSize: CGSize

    static func single(_ index: Int, natural: CGSize) -> SwitcherLayoutUnit {
        SwitcherLayoutUnit(
            members: [index],
            memberFrames: [CGRect(origin: .zero, size: natural)],
            naturalSize: natural
        )
    }

    /// Build a cluster from members' natural frames in ONE shared coordinate space (their real
    /// window frames): the unit is their union rect; each member keeps its offset within it. Members
    /// are ordered visually — left-to-right, then top-to-bottom — which is also the order they occupy
    /// in the expanded navigation row.
    static func cluster(members: [(index: Int, natural: CGRect)]) -> SwitcherLayoutUnit {
        let ordered = members.sorted { a, b in
            if abs(a.natural.minX - b.natural.minX) > 0.5 { return a.natural.minX < b.natural.minX }
            return a.natural.minY < b.natural.minY
        }
        let union = ordered.reduce(CGRect.null) { $0.union($1.natural) }
        let frames = ordered.map {
            CGRect(x: $0.natural.minX - union.minX, y: $0.natural.minY - union.minY,
                   width: $0.natural.width, height: $0.natural.height)
        }
        return SwitcherLayoutUnit(members: ordered.map(\.index), memberFrames: frames, naturalSize: union.size)
    }
}

/// One SOLVED flow-wrap unit: the unit's scaled `size` and each member's scaled frame within it.
/// A cluster renders as a fixed-size container with member cards at these frames; a singleton is
/// today's card (one zero-origin frame).
struct SwitcherGridUnit: Equatable {
    let members: [Int]
    let frames: [CGRect]
    let size: CGSize
    var isCluster: Bool { members.count > 1 }
}

/// The solved layout for one Space's window grid: a single uniform `scale` applied to every window's
/// real frame, the windows flow-wrapped into visual `rows` (each an array of indices into the input
/// windows), the per-window card `sizes` (index-aligned to the input), the total `contentSize`, and
/// whether the grid is taller than the canvas (so the view scrolls vertically). Both `SwitcherView`
/// (which renders) and `OverlayController` (which sizes the panel) read THIS one result, so the
/// rendered grid and the panel frame cannot drift. `units`/`unitRows` are the flow-wrap structure
/// (window-groups clusters are one unit); `rows` stays the EXPANDED per-window view of the same rows
/// (cluster members consecutive, visual order), which navigation, selection, and tests read.
struct SwitcherGridLayout: Equatable {
    let scale: CGFloat
    let rows: [[Int]]
    let sizes: [CGSize]
    let contentSize: CGSize
    let overflowsVertically: Bool
    var units: [SwitcherGridUnit] = []
    var unitRows: [[Int]] = []

    static let empty = SwitcherGridLayout(
        scale: 0, rows: [], sizes: [], contentSize: .zero, overflowsVertically: false
    )
}

/// Single source of truth for switcher grid metrics + the uniform-scale flow-layout solve, shared by
/// `SwitcherView` (which lays the cards out) and `OverlayController` (which sizes the panel). Every
/// window renders at its TRUE proportion (from its Accessibility/real frame) scaled by one global
/// factor — so relative sizes match Mission Control — and the windows wrap into a grid that fills the
/// canvas width. The factor is *solved*: the largest value whose wrapped grid still fits the canvas
/// height, capped by `kMax` and floored per-card by `minCardHeight`.
enum SwitcherLayout {
    // MARK: - Panel placement

    /// Reference panel height — kept for the onboarding wizard's demo strip framing.
    static let panelHeight: CGFloat = 240
    /// Minimum empty margin kept on each side of the screen when sizing the canvas.
    static let sideMargin: CGFloat = 40
    /// Fraction of the active screen's visible frame the canvas targets (the grid solves to fill it).
    static let canvasWidthFraction: CGFloat = 0.86
    static let canvasHeightFraction: CGFloat = 0.80

    // MARK: - Grid chrome

    /// Padding around the whole grid inside the rounded panel.
    static let gridContainerPadding: CGFloat = 26
    /// Spacing between adjacent cards in a visual row.
    static let gridCardSpacing: CGFloat = 16
    /// Spacing between visual rows.
    static let gridRowSpacing: CGFloat = 16
    /// Height reserved beneath the grid for the single highlighted-window title.
    static let titleAreaHeight: CGFloat = 44
    /// Left gutter reserved for the vertical Space indicator (only when >1 Space).
    static let rowIndicatorGutter: CGFloat = 26

    // MARK: - Scale solve tunables

    /// Upper bound on the uniform scale, so one or two windows don't balloon. Lower = all cards smaller
    /// (more Mission-Control-like density); the sparse case is what this governs (the dense case is
    /// already scale-limited by fitting the canvas height).
    static let kMax: CGFloat = 0.24
    /// Lower bound used while searching (paired with the per-card floor below).
    static let kMin: CGFloat = 0.02
    /// A card is never rendered shorter than this — a tiny window stays usable rather than a speck.
    static let minCardHeight: CGFloat = 84
    /// Proportion used when a window exposes no real and no usable displayed frame (the synthetic Hub
    /// entry / legacy path) — a 16:10 cell near the median.
    static let defaultNaturalSize = CGSize(width: 1280, height: 800)

    // MARK: - Card proportion

    /// The natural size a card's proportion derives from: the real (Accessibility) frame when present,
    /// else the displayed frame when usable, else a default 16:10 (D7). Used as the per-window input to
    /// the uniform-scale solve.
    static func naturalSize(realFrame: CGRect, frame: CGRect) -> CGSize {
        if realFrame.width > 1, realFrame.height > 1 { return realFrame.size }
        if frame.width > 1, frame.height > 1 { return frame.size }
        return defaultNaturalSize
    }

    // MARK: - Solve

    /// Card sizes at a given uniform scale, with the per-card `minCardHeight` floor applied (a floored
    /// card keeps its aspect by widening proportionally — the one place strict uniformity bends).
    static func cardSizes(naturals: [CGSize], scale: CGFloat) -> [CGSize] {
        naturals.map { n in
            var h = scale * n.height
            var w = scale * n.width
            if h < minCardHeight {
                let f = minCardHeight / max(h, 0.001)
                h = minCardHeight
                w *= f
            }
            return CGSize(width: max(w, 1), height: max(h, 1))
        }
    }

    /// Greedy left-to-right flow-wrap: a card starts a new visual row when adding it to the current row
    /// would exceed `canvasWidth`. Returns the rows (indices into `sizes`) and the total content size
    /// (max row width × summed band heights, a band = the tallest card in its row).
    ///
    /// Wrapping is **balanced**, not just greedy: greedy left-to-right fill determines the MINIMUM
    /// number of rows the cards need at this width, then — when that is more than one row — the cards
    /// are re-partitioned across that same number of rows so the WIDEST row is as narrow as possible (a
    /// minimax partition). This turns a greedy "4 + lonely 1" into a balanced "3 + 2" while leaving a
    /// fine single row (or an already-even multi-row) exactly as it is (the row count never changes).
    static func wrap(sizes: [CGSize], canvasWidth: CGFloat) -> (rows: [[Int]], contentSize: CGSize) {
        guard !sizes.isEmpty else { return ([], .zero) }
        // Minimum rows = greedy fill at the full canvas width.
        let greedy = packRows(sizes, cap: canvasWidth) ?? sizes.indices.map { [$0] }
        let rows: [[Int]]
        if greedy.count <= 1 {
            rows = greedy                       // a fine single row stays one row
        } else {
            // Re-balance into the same number of rows, minimizing the widest row.
            rows = balancedRows(sizes, into: greedy.count, canvasWidth: canvasWidth) ?? greedy
        }
        return (rows, contentSize(of: rows, sizes: sizes))
    }

    /// Greedy left-to-right fill into rows no wider than `cap` (inter-card spacing counted between
    /// adjacent cards). Returns `nil` if a single card is wider than `cap` (infeasible) — the caller
    /// only passes a `cap` ≥ the widest card, so this guards the degenerate case.
    private static func packRows(_ sizes: [CGSize], cap: CGFloat) -> [[Int]]? {
        var rows: [[Int]] = []
        var cur: [Int] = []
        var curW: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if s.width > cap + 0.5 { return nil }
            let prospective = cur.isEmpty ? s.width : curW + gridCardSpacing + s.width
            if !cur.isEmpty, prospective > cap {
                rows.append(cur)
                cur = [i]
                curW = s.width
            } else {
                cur.append(i)
                curW = prospective
            }
        }
        if !cur.isEmpty { rows.append(cur) }
        return rows
    }

    /// Partition the ordered cards into exactly `rowCount` rows minimizing the widest row (a minimax
    /// partition): binary-search the smallest row-width cap whose greedy fill still fits in `rowCount`
    /// rows. Because `rowCount` is the greedy minimum at `canvasWidth`, that smallest cap is ≤
    /// `canvasWidth`, so every balanced row still fits the canvas.
    private static func balancedRows(_ sizes: [CGSize], into rowCount: Int, canvasWidth: CGFloat) -> [[Int]]? {
        var lo = sizes.map(\.width).max() ?? 0    // a row can never be narrower than its widest card
        var hi = canvasWidth
        var best = packRows(sizes, cap: hi)
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if let packed = packRows(sizes, cap: mid), packed.count <= rowCount {
                best = packed
                hi = mid
            } else {
                lo = mid
            }
        }
        return best
    }

    // MARK: - Positional (nearest-x) navigation geometry

    /// Every window's x-span for one visual row of UNITS, in CENTER-RELATIVE coordinates (0 = the
    /// grid's horizontal center) and expanded-row order (cluster members consecutive). Rows render as
    /// horizontally centered HStacks of units, so a row of total width W spans [-W/2, +W/2] regardless
    /// of the grid's content width — which makes these positions comparable across rows of differing
    /// width AND across Spaces whose grids differ in width (every Space's grid centers in the same
    /// reel cell). A cluster member's span is its scaled frame offset within its unit — no inter-card
    /// spacing inside a cluster (spacing separates units only).
    static func windowSpans(unitRow: [Int], units: [SwitcherGridUnit])
        -> [(index: Int, span: ClosedRange<CGFloat>)] {
        guard !unitRow.isEmpty else { return [] }
        let rowWidth = unitRow.reduce(0) { $0 + (units.indices.contains($1) ? units[$1].size.width : 0) }
            + gridCardSpacing * CGFloat(max(unitRow.count - 1, 0))
        var x = -rowWidth / 2
        var spans: [(Int, ClosedRange<CGFloat>)] = []
        for u in unitRow {
            guard units.indices.contains(u) else { continue }
            let unit = units[u]
            for (member, frame) in zip(unit.members, unit.frames) {
                spans.append((member, (x + frame.minX)...(x + frame.maxX)))
            }
            x += unit.size.width + gridCardSpacing
        }
        return spans
    }

    /// Card x-intervals for one visual row of PLAIN cards (each its own unit) — the singleton view of
    /// `windowSpans`, index-aligned to the row's positions.
    static func rowIntervals(row: [Int], sizes: [CGSize]) -> [ClosedRange<CGFloat>] {
        let units = row.map { i in
            SwitcherGridUnit(members: [i], frames: [CGRect(origin: .zero, size: sizes[i])], size: sizes[i])
        }
        return windowSpans(unitRow: Array(units.indices), units: units).map(\.span)
    }

    /// The center-relative x-center of the card at `position` within its visual row.
    static func cardCenterX(row: [Int], sizes: [CGSize], position: Int) -> CGFloat {
        let intervals = rowIntervals(row: row, sizes: sizes)
        guard intervals.indices.contains(position) else { return 0 }
        return centerX(of: intervals[position])
    }

    static func centerX(of span: ClosedRange<CGFloat>) -> CGFloat {
        (span.lowerBound + span.upperBound) / 2
    }

    /// The position among `spans` that a vertical step should land on for a given anchor x
    /// (center-relative): the span minimizing the horizontal distance from the anchor (zero when the
    /// anchor falls inside the span — the card directly above/below always wins), ties broken toward
    /// the nearer span center, then leftmost.
    static func nearestSpan(toAnchorX anchorX: CGFloat, spans: [ClosedRange<CGFloat>]) -> Int {
        guard !spans.isEmpty else { return 0 }
        var best = 0
        var bestGap = CGFloat.greatestFiniteMagnitude
        var bestCenter = CGFloat.greatestFiniteMagnitude
        for (pos, span) in spans.enumerated() {
            let gap = max(max(span.lowerBound - anchorX, anchorX - span.upperBound), 0)
            let center = abs(centerX(of: span) - anchorX)
            if gap < bestGap - 0.5 || (abs(gap - bestGap) <= 0.5 && center < bestCenter - 0.5) {
                best = pos
                bestGap = gap
                bestCenter = center
            }
        }
        return best
    }

    /// The position within a PLAIN row (each card its own unit) nearest the anchor — the singleton
    /// view of `nearestSpan`.
    static func nearestPosition(toAnchorX anchorX: CGFloat, row: [Int], sizes: [CGSize]) -> Int {
        nearestSpan(toAnchorX: anchorX, spans: rowIntervals(row: row, sizes: sizes))
    }

    /// Content size of a wrapped layout: widest row × summed band heights (a band = the tallest card
    /// in its row), with inter-card and inter-row spacing.
    private static func contentSize(of rows: [[Int]], sizes: [CGSize]) -> CGSize {
        var totalH: CGFloat = 0
        var maxW: CGFloat = 0
        for (ri, row) in rows.enumerated() {
            let bandH = row.map { sizes[$0].height }.max() ?? 0
            let rowW = row.reduce(0) { $0 + sizes[$1].width }
                + gridCardSpacing * CGFloat(max(row.count - 1, 0))
            totalH += bandH
            if ri > 0 { totalH += gridRowSpacing }
            maxW = max(maxW, rowW)
        }
        return CGSize(width: maxW, height: totalH)
    }

    /// Backward-compatible entry: every window is its own flow-wrap unit (no groups). Produces the
    /// exact layout the pre-unit solve did.
    static func solveGrid(naturals: [CGSize], canvas: CGSize, maxScale: CGFloat = kMax) -> SwitcherGridLayout {
        solveGrid(
            units: naturals.enumerated().map { .single($0.offset, natural: $0.element) },
            canvas: canvas, maxScale: maxScale
        )
    }

    /// Per-unit sizes at a uniform scale: a singleton keeps the per-card `minCardHeight` floor (via
    /// `cardSizes`); a cluster is exactly `scale × union` — flooring one member would break the
    /// mirrored real arrangement, so the readability floor applies to the unit as a whole only
    /// implicitly (a cluster is by construction at least as large as its members).
    static func unitSizes(units: [SwitcherLayoutUnit], scale: CGFloat) -> [CGSize] {
        units.map { unit in
            if unit.members.count == 1 {
                return cardSizes(naturals: [unit.naturalSize], scale: scale)[0]
            }
            return CGSize(width: max(unit.naturalSize.width * scale, 1),
                          height: max(unit.naturalSize.height * scale, 1))
        }
    }

    /// Solve the uniform scale that best fills the canvas: the largest scale whose wrapped grid still
    /// fits `canvas.height`, capped at `maxScale` (the configurable window-size cap, default `kMax`) and
    /// at the width that lets the widest UNIT fit. If the grid overflows the canvas height even at the
    /// smallest scale (many windows), return the smallest layout flagged as vertically overflowing so
    /// the view scrolls (D1, D5). Wrapping/balancing operate on units; `rows`/`sizes` are the expanded
    /// per-window views of the same solution.
    static func solveGrid(units: [SwitcherLayoutUnit], canvas: CGSize, maxScale: CGFloat = kMax) -> SwitcherGridLayout {
        guard !units.isEmpty, canvas.width > 1, canvas.height > 1 else { return .empty }

        let maxNaturalWidth = units.map(\.naturalSize.width).max() ?? 1
        let kFitWidth = canvas.width / max(maxNaturalWidth, 1)
        let hiK = min(max(maxScale, kMin), kFitWidth)

        func height(at k: CGFloat) -> CGFloat {
            wrap(sizes: unitSizes(units: units, scale: k), canvasWidth: canvas.width).contentSize.height
        }

        var chosenK = hiK
        var overflow = false
        if height(at: hiK) > canvas.height {
            // Binary-search the largest scale that still fits the canvas height.
            var lo = kMin
            var hi = hiK
            for _ in 0..<28 {
                let mid = (lo + hi) / 2
                if height(at: mid) <= canvas.height { lo = mid } else { hi = mid }
            }
            chosenK = lo
            // Even the floored-minimum layout doesn't fit: keep it and scroll.
            if height(at: kMin) > canvas.height {
                chosenK = max(kMin, lo)
                overflow = height(at: chosenK) > canvas.height
            }
        }

        let solvedSizes = unitSizes(units: units, scale: chosenK)
        let (flowRows, contentSize) = wrap(sizes: solvedSizes, canvasWidth: canvas.width)
        // Stack the flow BOTTOM-TO-TOP: `wrap` returns rows in flow order (the first line — containing
        // window 0, the frontmost/MRU window — first); reversing them into visual top-to-bottom order
        // puts that first line LAST = the bottom row, and later windows wrap UPWARD. So entering a Space
        // lands on the first window at the bottom-left and a swipe-up walks older windows toward the top
        // edge, then to the next Space (mirroring the Space dots, which also count up from the bottom). A
        // single row reverses to itself (no-op). Navigation is unchanged: `rows` stays visual
        // top-to-bottom, exactly what `currentGridRow` / `moveVertical` (up = row-1 toward the top) assume.
        let unitRows = Array(flowRows.reversed())

        // Solved units: singleton member frames fill the (possibly floored) card; cluster member
        // frames are the natural offsets/sizes at the chosen scale (exact mirrored arrangement).
        let solved: [SwitcherGridUnit] = units.enumerated().map { u, unit in
            if unit.members.count == 1 {
                return SwitcherGridUnit(
                    members: unit.members,
                    frames: [CGRect(origin: .zero, size: solvedSizes[u])],
                    size: solvedSizes[u]
                )
            }
            let frames = unit.memberFrames.map {
                CGRect(x: $0.minX * chosenK, y: $0.minY * chosenK,
                       width: max($0.width * chosenK, 1), height: max($0.height * chosenK, 1))
            }
            return SwitcherGridUnit(members: unit.members, frames: frames, size: solvedSizes[u])
        }

        // Expanded per-window views: rows (cluster members consecutive, visual order) + sizes.
        let rows = unitRows.map { row in row.flatMap { solved[$0].members } }
        let windowCount = units.reduce(0) { $0 + $1.members.count }
        var sizes = [CGSize](repeating: .zero, count: windowCount)
        for su in solved {
            for (m, f) in zip(su.members, su.frames) where sizes.indices.contains(m) {
                sizes[m] = f.size
            }
        }
        return SwitcherGridLayout(
            scale: chosenK, rows: rows, sizes: sizes,
            contentSize: contentSize, overflowsVertically: overflow,
            units: solved, unitRows: unitRows
        )
    }
}
