# Tasks: switcher-positional-vertical-nav

## 1. Geometry helpers (SwitcherLayout)

- [x] 1.1 Add pure static helpers to `SwitcherLayout`: per-card x-intervals for a visual row (`rows`+`sizes`+`gridCardSpacing`, centered within a given content width) and a nearest-to-anchor picker (interval-distance, tie → nearer center, then leftmost), anchor expressed center-relative
- [x] 1.2 Unit-test the helpers in `SwitcherModelTests` (or a dedicated section): centered-row interval math matches `wrap` output; landing picks the overlapping card; tie-breaking; single-card row

## 2. SwitcherModel positional navigation

- [x] 2.1 Add the `preferredX` sticky anchor to `SwitcherModel`: set on first vertical step from the selected card's x-center (center-relative); cleared by `moveHorizontal`, `setColumn`, `setRowAndColumn`, `setRows`, and `setRow`
- [x] 2.2 Rewrite `moveVertical` to land positionally in the adjacent visual row using the anchor (keeping the `VerticalMove` edge contract unchanged)
- [x] 2.3 Add `setRowEntering(_:from:)` (or equivalent) that switches Space and lands positionally — bottom visual row when entering upward, top when entering downward — using the retained anchor
- [x] 2.4 Unit tests: nearest-x landing up/down; anchor held across a multi-row run (straight line through a narrow middle card); horizontal step re-anchors; fresh `setRows` clears the anchor; positional Space entry lands bottom/top row nearest-x; single-row Space still reports `atEdge` immediately

## 3. Controller + coordinator plumbing

- [x] 3.1 Add `OverlayController.updateRowPositional(_:entering:)` delegating to the model's positional Space entry (leave `updateRow` as-is for non-vertical callers)
- [x] 3.2 Route `AppCoordinator.switchSpace` (vertical edge crossing) through the positional entry, preserving the `prefetchCurrentRow()` → `beginSlideFreeze()` sequencing and wrap/clamp behavior
- [x] 3.3 Route ⌘-Tab arrow Up/Down through the same grid-vertical path as `gestureDidStepRow` (next-tick dispatch as with the other keyboard events); update `KeyboardSwitcher` doc comments to describe grid-row navigation

## 4. Verify

- [x] 4.1 `swift build` and `swift test` pass (all existing switcher tests still green)
- [x] 4.2 Re-read the delta specs and confirm every scenario is covered by a test or by directly-observable behavior; update specs if implementation surfaced drift
