import CoreGraphics

/// Single source of truth for switcher card metrics, shared by `SwitcherView` (which lays the
/// cards out) and `OverlayController` (which sizes the panel). Keeping these in one place means
/// the computed panel width cannot drift from the actual card layout.
enum SwitcherLayout {
    /// Inner content width of a card (thumbnail + title column).
    static let cardInnerWidth: CGFloat = 200
    static let cardHeight: CGFloat = 150
    /// Padding around each card (inside the strip).
    static let cardPadding: CGFloat = 8
    /// Spacing between adjacent cards.
    static let interCardSpacing: CGFloat = 14
    /// Padding around the whole strip (inside the rounded container).
    static let stripPadding: CGFloat = 20

    /// Overall panel height.
    static let panelHeight: CGFloat = 240
    /// Minimum empty margin kept on each side of the screen when clamping a wide strip.
    static let sideMargin: CGFloat = 40

    /// Left gutter reserved for the vertical Space-row indicator (only when >1 row).
    static let rowIndicatorGutter: CGFloat = 26

    /// Outer width a single card occupies, including its own padding.
    static var cardOuterWidth: CGFloat { cardInnerWidth + 2 * cardPadding }

    /// Total content width for `count` cards (what the strip wants to be), plus the row-indicator
    /// gutter when there is more than one Space-row.
    static func contentWidth(for count: Int, withRowIndicator: Bool = false) -> CGFloat {
        let gutter = withRowIndicator ? rowIndicatorGutter : 0
        guard count > 0 else { return stripPadding * 2 + gutter }
        return stripPadding * 2 + gutter
            + CGFloat(count) * cardOuterWidth
            + CGFloat(count - 1) * interCardSpacing
    }
}
