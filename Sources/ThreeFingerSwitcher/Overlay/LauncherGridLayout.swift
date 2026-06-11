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

    /// Window height: driven *solely* by the active band's item rows (so a 2-row band is exactly two
    /// rows tall, a 3-row band three), clamped to the min/max bounds. The band-title list divides this
    /// same height evenly between its titles, so it never makes the window taller than the items do —
    /// and switching between same-row-count bands yields an identical height (no jitter).
    static func windowHeight(itemCount: Int) -> CGFloat {
        min(max(containerHeight(forItemCount: itemCount), minHeight), maxHeight)
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
