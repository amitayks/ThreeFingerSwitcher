import CoreGraphics
import Foundation

/// Metrics for the Launchpad-style launcher grid, shared by `LauncherView` (lays out the grid) and
/// `LauncherOverlayController` (sizes the panel) so the two can't drift.
enum LauncherGridLayout {
    /// Fixed number of columns (Launchpad-like). The container is a constant width; bands with
    /// fewer items just fill fewer cells in the first row.
    static let columns = 6
    static let cellWidth: CGFloat = 132
    static let cellHeight: CGFloat = 120
    static let iconSize: CGFloat = 76
    static let spacing: CGFloat = 16
    static let containerPadding: CGFloat = 26
    /// Height of the category-tabs strip at the top.
    static let tabsHeight: CGFloat = 56
    /// Rows shown before the grid scrolls (vertical overflow).
    static let maxVisibleRows = 4

    /// Constant container width: all columns + inter-cell spacing + padding.
    static var containerWidth: CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(columns - 1) * spacing + 2 * containerPadding
    }

    /// Rows needed to show `count` items at the fixed column count.
    static func rows(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        return Int((Double(count) / Double(columns)).rounded(.up))
    }

    /// Container height for a band with `count` items (capped to `maxVisibleRows`; the grid scrolls
    /// beyond that).
    static func containerHeight(forItemCount count: Int) -> CGFloat {
        let visibleRows = min(max(rows(for: count), 1), maxVisibleRows)
        let gridHeight = CGFloat(visibleRows) * cellHeight + CGFloat(visibleRows - 1) * spacing
        return tabsHeight + gridHeight + 2 * containerPadding
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
