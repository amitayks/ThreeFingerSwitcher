## Context

The overlay is a non-activating `NSPanel` centered horizontally on the active screen, hosting a SwiftUI `ScrollView` + `HStack` of cards. Today `OverlayController.layout()` sets a fixed panel width (`min(visibleWidth - 80, 1200)`) regardless of card count, so a short list leaves the cards left-aligned with empty space. The window list is snapshotted at gesture start, so the card count is known and fixed for the duration of a gesture.

## Goals / Non-Goals

**Goals:**
- Short list → container hugs the cards and is centered on screen.
- Overflow → clamp to max width, centered, scroll-to-reveal (unchanged).

**Non-Goals:**
- No change to gesture logic, enumeration, raising, the highlight, or the auto-scroll behavior.
- No per-card resizing or wrapping to multiple rows.

## Decisions

### D1 — Size the panel to the content; centering falls out for free
Because the panel is already centered on screen, if we size the panel width to the content width when it fits, left-aligned content inside renders as visually centered and the rounded background hugs the cards. So the change is: at `show()` time compute
`contentWidth = outerPadding*2 + N*cardOuterWidth + (N-1)*spacing`,
`maxWidth = activeScreen.visibleFrame.width - sideMargin`,
`panelWidth = min(contentWidth, maxWidth)`, then center the panel. `overflow = contentWidth > maxWidth`.
- *Alternative considered*: keep the wide panel and center the `HStack` inside via SwiftUI alignment. Rejected — the rounded background would still span full width (doesn't "wrap the windows"), and it complicates the overflow/scroll case.

### D2 — Single source of truth for card metrics
Extract `cardWidth`, inter-card `spacing`, and outer `padding` into one shared place (e.g. an `enum SwitcherLayout`) used by both `SwitcherView` (layout) and `OverlayController` (width computation) so they cannot drift.

### D3 — Keep the ScrollView; it just doesn't scroll when content fits
Retain the `ScrollViewReader`/`ScrollView`. When `panelWidth == contentWidth`, there is nothing to scroll. When overflowing, the existing `scrollTo(selectedIndex, anchor: .center)` keeps the highlight visible. Disable bounce when not overflowing so it doesn't drift.

## Risks / Trade-offs

- **[Metric drift between view and controller]** → Mitigation: D2 shared constants; compute `cardOuterWidth` from the same numbers the view uses (card width + its internal padding).
- **[Off-by-a-few-pixels hug]** → Mitigation: include the exact paddings in `contentWidth`; a small symmetric fudge is acceptable since the panel is centered.
- **[Very large lists]** → Mitigation: `maxWidth` clamp + existing scroll path already handle this; unchanged.
