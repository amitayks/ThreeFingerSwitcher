# Design: switcher-positional-vertical-nav

## Context

`SwitcherModel` already navigates a real 2D grid: `SwitcherGridLayout` (solved by `SwitcherLayout.solveGrid`) carries the visual `rows` (index arrays into the Space's windows), the exact per-card `sizes`, and the spacing constants; `SwitcherView` renders each row as a **centered** `HStack` inside a VStack. But `moveVertical` lands on `rows[r±1].first` — the leftmost card — and a Space-edge crossing (`AppCoordinator.switchSpace` → `OverlayController.updateRow` → `SwitcherModel.setRow`) resets the column to 0. The ⌘-Tab driver's Up/Down arrows don't touch grid rows at all: they jump to the adjacent Space (`KeyboardSwitcher.arrow` → coordinator's Space jump).

Everything needed for positional landing is already in the model (pure, main-actor, unit-tested in `SwitcherModelTests`), so this is a model-plus-plumbing change with no new UI, permissions, or persistence.

## Goals / Non-Goals

**Goals:**
- Vertical steps land on the card the user is visually above/below (nearest-x), within a Space and across Space edges.
- A run of vertical steps holds a straight line (sticky preferred-x anchor) instead of drifting through narrow cards.
- Trackpad scrub and ⌘-Tab Up/Down behave identically (one shared model path).

**Non-Goals:**
- No change to horizontal scrub, the linear Tab/Shift-Tab reel flow (its next-Space-first-window / previous-Space-last-window landings stay), the opening position (current Space, first window bottom-left), commit, or Esc.
- No new tunables — the landing rule is geometric, nothing to tune.
- No changes to the reel animation, thumbnail freeze/seed machinery, or panel sizing.

## Decisions

### D1 — Geometry helpers live in `SwitcherLayout`, pure and static
Add pure helpers that, given a visual row (`[Int]`), the solved `sizes`, and the grid `contentSize.width`, return each card's horizontal interval: row width = Σ widths + `gridCardSpacing`·(n−1); row start = `(contentWidth − rowWidth)/2` (rows are centered — this mirrors `SwitcherView`'s layout exactly, and `contentSize` is already the single source of truth both view and controller read). Keeping them in `SwitcherLayout` keeps view/model geometry from drifting and makes the landing rule unit-testable without a view.

### D2 — The anchor is a **center-relative** x offset (`x − contentWidth/2`)
Every Space's grid is centered in the same reel cell (`maxContentSize`), so an offset from the grid's center is the one coordinate that is stable both across rows of differing width **and across Spaces of differing grid width**. Storing the anchor center-relative makes the cross-Space landing correct for free. (Absolute left-edge coordinates would shift between Spaces whose grids differ in width.)

### D3 — Landing rule: minimal distance to the card's x-interval, then nearest center
Target card = the card in the destination row minimizing `distance(anchorX, cardInterval)` (0 when the anchor falls inside the card's span; else the gap to the nearest edge). Ties break to the nearer card center, then leftmost. Interval-distance beats nearest-center for wide cards: stepping down from a narrow card onto a wide card directly beneath must land there even when the wide card's *center* is far away.

### D4 — Sticky anchor lifecycle in `SwitcherModel`
`private var preferredX: CGFloat?`
- **Set** on a vertical step when nil, from the currently selected card's x-center (converted center-relative).
- **Reused** by every subsequent vertical step, including the positional Space-edge landing.
- **Cleared** by: `moveHorizontal`, `setColumn`, `setRowAndColumn` (the linear ⌘-Tab reel flow), `setRows` (fresh show), and `setRow` (non-vertical Space entry).
This is exactly the tvOS/grid-focus "preferred x" idiom: horizontal intent re-anchors, vertical intent holds the line.

### D5 — Space-edge crossing lands positionally via a new model entry point
`moveVertical` keeps its signature and `VerticalMove.atEdge(spaceDelta)` contract. `AppCoordinator.switchSpace` (only reached from a vertical scrub or, now, arrow Up/Down) calls a new `OverlayController.updateRowPositional(row, entering: .fromTop/.fromBottom)` → `SwitcherModel.setRowEntering(...)`, which sets `currentRow` and selects, using the anchor, in the **bottom** visual row when entering upward and the **top** visual row when entering downward (spatially continuous with the reel's vertical stacking). The existing `updateRow`/`setRow` (column-0 reset) remains for any non-vertical caller and for API stability. `prefetchCurrentRow()` + `beginSlideFreeze()` sequencing in `switchSpace` is untouched.

### D6 — ⌘-Tab Up/Down routes to the shared grid-vertical path
The coordinator's `KeyboardSwitcherDelegate` arrow handling for `.up`/`.down` calls the same logic as `gestureDidStepRow(±1)` (dispatched to the next tick exactly as the other keyboard events are — the tap callback must stay cheap). Wrap-vs-clamp at the first/last Space follows `settings.wrapAtEnds`, as the trackpad path already does. `KeyboardSwitcher` itself only needs its doc comment updated — the `SwitcherArrow` enum and event plumbing are unchanged.

## Risks / Trade-offs

- [Behavior change for ⌘-Tab users: Up/Down no longer jumps a whole Space per press] → With a single-row Space grid, every vertical step is immediately `atEdge`, so the felt behavior there is *identical* to today. Only multi-row grids change — precisely where the old behavior was unusable.
- [Anchor could go stale across a mid-session snapshot refresh (`setRows`)] → `setRows` clears it; the next vertical step re-anchors from the current selection.
- [Geometry drift between `SwitcherView` rendering and `SwitcherLayout` helpers] → The helpers use the same constants and the same centering rule as the view (`contentSize` is already shared); a unit test locks the interval math to the wrap output.
- [Selected-card-kept-visible scrolling in an overflowing grid] → unchanged; it keys off `selectedIndex`, which this change still mutates through the same published property.

## Migration Plan

Pure runtime-behavior change in Core; no data, settings, or permission migration. Ship in the next stable-signed rebuild. Rollback = revert the commit.

## Open Questions

None — the landing rule, anchor lifecycle, and keyboard routing are fully decided above.
