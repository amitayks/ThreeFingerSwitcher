import CoreGraphics
import Foundation

/// Metrics for the Launchpad-style launcher grid, shared by `LauncherView` (lays out the grid) and
/// `LauncherOverlayController` (sizes the panel) so the two can't drift.
enum LauncherGridLayout {
    /// Fixed number of columns (Launchpad-like). The container is a constant width; bands with
    /// fewer items just fill fewer cells in the first row.
    static let columns = 6
    static let cellWidth: CGFloat = 132
    /// Per-cell height budgets the icon tile (`iconSize + 30`) + the inter-element spacing + the title
    /// label beneath it, so a row reserves room for the item titles (not just the icons). The window
    /// height is summed from this, so labels are never clipped at the container's bottom edge.
    static let cellHeight: CGFloat = 136
    static let iconSize: CGFloat = 76
    static let spacing: CGFloat = 16
    static let containerPadding: CGFloat = 26
    /// Height of the category-tabs strip — no longer summed into the grid container height (the bands
    /// now live in the left list, not a top strip), kept only for the Clipboard layout's reference.
    static let tabsHeight: CGFloat = 56
    /// Rows shown before the grid scrolls (vertical overflow).
    static let maxVisibleRows = 4
    /// Top inset inside the grid's scroll view (breathing room above the first row). Budgeted into the
    /// window height (below) so a band that fits within `maxVisibleRows` never scrolls.
    static let gridTopInset: CGFloat = 14

    // MARK: - Band-icon list (the left column)

    /// The bands render as a vertical list of **icons** (not titles). Each icon's tile size.
    static let bandIconSize: CGFloat = 30
    /// Padding the icon's hit/highlight tile adds around the glyph — the REAL per-row height is
    /// `bandIconSize + bandIconTilePadding` (shared with `LauncherView.bandIcon` so the window
    /// sizing math and the rendered rows can never drift apart again).
    static let bandIconTilePadding: CGFloat = 18
    /// Fixed (small) vertical gap between band icons — the list sits centered in the column, not spread.
    static let bandRowSpacing: CGFloat = 12
    /// Fixed width of the left band-icon column (icon tile + padding on each side + the gap to the grid).
    static let bandColumnWidth: CGFloat = 78

    // MARK: - Window sizing

    /// Window-height bounds: the panel grows from this min toward this max as the active band's item
    /// rows need more room; beyond the max, the grid scrolls inside. The max comfortably fits the full
    /// `maxVisibleRows` (so two/three/four rows never scroll); only a fifth row begins scrolling.
    static let minHeight: CGFloat = 280
    static let maxHeight: CGFloat = 760

    /// Constant container width: all columns + inter-cell spacing + padding.
    static var containerWidth: CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(columns - 1) * spacing + 2 * containerPadding
    }

    /// Rows needed to show `count` items at the fixed column count.
    static func rows(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        return Int((Double(count) / Double(columns)).rounded(.up))
    }

    /// Grid content height for a band with `count` items (capped to `maxVisibleRows`; the grid scrolls
    /// beyond that). `cellHeight` budgets each item's title, and `gridTopInset` matches the grid's own
    /// top padding — so up to `maxVisibleRows` rows fit exactly, titles included, without scrolling.
    static func containerHeight(forItemCount count: Int) -> CGFloat {
        let visibleRows = min(max(rows(for: count), 1), maxVisibleRows)
        let gridHeight = CGFloat(visibleRows) * cellHeight + CGFloat(visibleRows - 1) * spacing
        return gridHeight + gridTopInset + 2 * containerPadding
    }

    /// Height the band-icon list needs to show every band's fixed-size icon TILE (icon + tile
    /// padding — the view's actual row height) + gaps + the container's vertical padding. This is
    /// the SwiftUI content's minimum height for the list column: the hosting view enforces it on
    /// the window via Auto Layout, so a panel frame computed below it gets force-grown a beat
    /// after its own animation — the mid-switch double-stretch. Zero for a single band (no list).
    static func bandListHeight(bandCount: Int) -> CGFloat {
        guard bandCount > 1 else { return 0 }
        let rowHeight = bandIconSize + bandIconTilePadding
        return CGFloat(bandCount) * rowHeight + CGFloat(bandCount - 1) * bandRowSpacing
            + 2 * containerPadding
    }

    /// Window height: the LARGER of the active band's item-row demand and the band-icon list's
    /// demand, clamped to the min/max bounds. The list term matters with many bands: the icons are
    /// FIXED-size (they don't compress to fit), so sizing from the item rows alone makes the
    /// container grow for the list a beat after fitting the rows — the mid-switch stretch jitter.
    /// Taking the max sizes the container once: band switches only change the height when a band's
    /// rows genuinely need more room than the list, and never below what the list needs.
    static func windowHeight(itemCount: Int, bandCount: Int = 1) -> CGFloat {
        let wanted = max(containerHeight(forItemCount: itemCount), bandListHeight(bandCount: bandCount))
        return min(max(wanted, minHeight), maxHeight)
    }
}

/// Metrics for the Clipboard band's master-detail layout (key list + value preview). Sized large
/// enough to show several keys and a sizeable value preview at once — deliberately independent of the
/// icon-grid `LauncherGridLayout`.
enum ClipboardBandLayout {
    static let containerWidth: CGFloat = 940
    static let containerHeight: CGFloat = 580
    /// Width of the left key column; the rest is the value preview.
    static let keyColumnWidth: CGFloat = 340
    static let keyRowHeight: CGFloat = 40
    /// Visible key rows before the list scrolls.
    static let maxVisibleKeyRows = 11
    static let tabsHeight = LauncherGridLayout.tabsHeight
    static let padding = LauncherGridLayout.containerPadding
}
