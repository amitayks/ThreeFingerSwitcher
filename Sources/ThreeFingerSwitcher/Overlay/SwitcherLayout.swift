import CoreGraphics

/// The solved layout for one Space's window grid: a single uniform `scale` applied to every window's
/// real frame, the windows flow-wrapped into visual `rows` (each an array of indices into the input
/// windows), the per-window card `sizes` (index-aligned to the input), the total `contentSize`, and
/// whether the grid is taller than the canvas (so the view scrolls vertically). Both `SwitcherView`
/// (which renders) and `OverlayController` (which sizes the panel) read THIS one result, so the
/// rendered grid and the panel frame cannot drift.
struct SwitcherGridLayout: Equatable {
    let scale: CGFloat
    let rows: [[Int]]
    let sizes: [CGSize]
    let contentSize: CGSize
    let overflowsVertically: Bool

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

    /// Solve the uniform scale that best fills the canvas: the largest scale whose wrapped grid still
    /// fits `canvas.height`, capped at `maxScale` (the configurable window-size cap, default `kMax`) and
    /// at the width that lets the widest card fit. If the grid overflows the canvas height even at the
    /// smallest scale (many windows), return the smallest layout flagged as vertically overflowing so
    /// the view scrolls (D1, D5).
    static func solveGrid(naturals: [CGSize], canvas: CGSize, maxScale: CGFloat = kMax) -> SwitcherGridLayout {
        guard !naturals.isEmpty, canvas.width > 1, canvas.height > 1 else { return .empty }

        let maxNaturalWidth = naturals.map(\.width).max() ?? 1
        let kFitWidth = canvas.width / max(maxNaturalWidth, 1)
        let hiK = min(max(maxScale, kMin), kFitWidth)

        func height(at k: CGFloat) -> CGFloat {
            wrap(sizes: cardSizes(naturals: naturals, scale: k), canvasWidth: canvas.width).contentSize.height
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

        let sizes = cardSizes(naturals: naturals, scale: chosenK)
        let (flowRows, contentSize) = wrap(sizes: sizes, canvasWidth: canvas.width)
        // Stack the flow BOTTOM-TO-TOP: `wrap` returns rows in flow order (the first line — containing
        // window 0, the frontmost/MRU window — first); reversing them into visual top-to-bottom order
        // puts that first line LAST = the bottom row, and later windows wrap UPWARD. So entering a Space
        // lands on the first window at the bottom-left and a swipe-up walks older windows toward the top
        // edge, then to the next Space (mirroring the Space dots, which also count up from the bottom). A
        // single row reverses to itself (no-op). Navigation is unchanged: `rows` stays visual
        // top-to-bottom, exactly what `currentGridRow` / `moveVertical` (up = row-1 toward the top) assume.
        let rows = Array(flowRows.reversed())
        return SwitcherGridLayout(
            scale: chosenK, rows: rows, sizes: sizes,
            contentSize: contentSize, overflowsVertically: overflow
        )
    }
}
