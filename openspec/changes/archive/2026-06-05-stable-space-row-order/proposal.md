## Why

The switcher's Space-rows are reordered on every open so the current Space is forced to row 0, and the other Spaces sort by raw `CGSSpaceID` rather than the order you see in Mission Control. The same Space therefore lands on a different row each time depending on where you currently are, which breaks spatial muscle memory. The archived `switcher-overlay` spec already calls for rows "in Space order ... starting on the current Space's row" — the implementation diverged from it.

## What Changes

- Order Space-rows by **true Mission Control order** (the display order from `CGSCopyManagedDisplaySpaces`), so a given Space always occupies the same row across reopens.
- Highlight the current Space **in place** (start row = its position in that order) instead of pulling it to row 0.
- Keep **omitting empty Spaces** (a Space with no switchable window cannot be committed to — there is nothing to raise — and the direct Space-switch API is Dock-gated and unavailable to this app).
- No change to data freshness: the grid is already re-snapshotted on each open, so adding/removing a window or Space updates the rows on the next open.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `switcher-overlay`: the "Space-row display" requirement changes from "current Space first" to "rows in true Mission Control order, stable across reopens, with the current Space highlighted at its own position". Empty-Space omission is unchanged.

## Impact

- `Sources/ThreeFingerSwitcher/Windows/WindowInfo.swift` — add a Mission Control order index to the window model.
- `Sources/ThreeFingerSwitcher/Windows/WindowService.swift` — populate that index from the existing `SpaceModel.indexBySpace` in both the cross-Space and legacy snapshot paths.
- `Sources/ThreeFingerSwitcher/Windows/SpaceGrouping.swift` — sort rows by the index, compute `startRow` as the current Space's position, label rows by true Space number.
- `Tests/ThreeFingerSwitcherTests/SpaceGroupingTests.swift` — rewrite assertions for the new ordering contract.
- No changes to raising/focus, gesture recognition, thumbnails, the overlay panel, model, or view (they already honor an arbitrary start row and anchor row 0 at the bottom of the indicator).
