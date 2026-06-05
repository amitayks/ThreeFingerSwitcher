## Context

The switcher builds a 2D grid each time the gesture activates: `AppCoordinator.gestureDidActivate()` calls `WindowService.snapshot()` (a fresh all-Spaces enumeration) and feeds the flat list to `SpaceGrouping.group()`, which buckets windows into Space-rows. The grid is the source of truth in `SwitcherModel`; the overlay renders one row at a time with a vertical dot indicator (row 0 anchored at the bottom) and a horizontal card strip.

Today `SpaceGrouping.group()`:
- sorts buckets **current-first**, then by ascending raw `CGSSpaceID`;
- returns `startRow = 0` (the current bucket is always first).

Two consequences: (1) a Space's row position changes depending on which Space is current, so reopening reshuffles the layout; (2) raw `CGSSpaceID` is roughly *creation* order and does not track the visual Mission Control order after a drag-reorder.

The order this change wants already exists upstream: `SpaceService.currentModel()` returns `indexBySpace` (built from `CGSCopyManagedDisplaySpaces`, i.e. display/Mission-Control order, covering every Space including empty ones), and `WindowService.snapshot()` already reads it as a sort tiebreaker — then discards it. We carry it through to the grouping instead.

## Goals / Non-Goals

**Goals:**
- Space-rows appear in true Mission Control order, identical across reopens.
- The current Space is highlighted at its own row position (`startRow` = that position), not moved to row 0.
- `SpaceGrouping.group()` stays a pure function of `[WindowInfo]` (unit-testable, no AppKit/CGS state).

**Non-Goals:**
- No change to data freshness (the grid is already re-snapshotted each open).
- No change to raising/focus, gesture thresholds, thumbnails, the overlay panel, model, or view.
- No support for committing to an *empty* Space (no window to raise; the direct Space-switch API is Dock-gated and unavailable here). Empty Spaces stay omitted.
- Multi-display ordering is best-effort (see Risks); single-display is fully correct.

## Decisions

### Carry the order index on `WindowInfo` (vs. passing a map into `group()`)
Add `spaceIndex: Int` to `WindowInfo`, populated in `snapshot()` from `model.indexBySpace[placement.space]`. The grouping then sorts buckets by `spaceIndex` ascending.

Alternative considered: change `SpaceGrouping.group(_:spaceOrder:)` to take an order map and pass `model.indexBySpace` from the call site. Rejected because `gestureDidActivate()` only holds the `[WindowInfo]` returned by `snapshot()`, not the `SpaceModel`; supplying the map would force either re-fetching `SpaceService.currentModel()` in the coordinator (a redundant CGS read that could disagree with the snapshot's read) or widening the snapshot's return type. Carrying the index on each window captures it atomically in the same snapshot and keeps `group()`'s signature a pure function of its windows.

### `startRow` = position of the current bucket
A bucket is current if any of its windows has `isOnCurrentSpace == true` (unchanged rule). After sorting by `spaceIndex`, `startRow` is the index of the first current bucket, or 0 if none. `SwitcherModel.setRows(startRow:)` already clamps and applies an arbitrary start row, so no model/view change is needed.

### Labels reflect the true Space number
Row labels become `spaceIndex + 1` (the 1-based Mission Control number) rather than the 1-based row position, so a label stays meaningful when an earlier Space is empty and omitted. Labels are not rendered today (the indicator uses dots), so this is a correctness/forward-looking choice with no visible effect now.

### Legacy path
`legacySnapshot()` (used when private CGS symbols are unavailable; produces a single current Space with `spaceID == nil`) sets `spaceIndex: 0`. The single bucket sorts trivially, `startRow` is 0, label is "1".

## Risks / Trade-offs

- **Multi-display** → `orderedSpaceIDs` concatenates Spaces across displays in display-iteration order, so cross-display row order and `startRow` are best-effort. Mitigation: single-display (the common case) is fully correct; no regression versus today's current-first behavior. Out of scope to special-case.
- **Existing tests encode the old contract** → `SpaceGroupingTests` asserts current-first ordering and `startRow == 0`. Mitigation: rewrite those tests as part of this change (the grouping is pure and fully covered, so the new contract is easy to pin down).
- **New required field on `WindowInfo`** → every construction site must pass `spaceIndex`. Mitigation: only three sites exist (`snapshot()`, `legacySnapshot()`, the test helper); all are updated here.
