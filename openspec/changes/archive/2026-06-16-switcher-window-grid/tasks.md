## 1. Pure layout solve (foundation, testable)

- [x] 1.1 In `Overlay/SwitcherLayout.swift`, add an aspect helper that derives a card proportion from a window's `realFrame`, falling back to `frame` when usable and otherwise a default 16:10 (D7).
- [x] 1.2 Add tunable layout constants: canvas size fraction of the visible frame, `kMax`, `minCardSize`, inter-card spacing, inter-row spacing, canvas padding.
- [x] 1.3 Implement the pure flow-wrap function: given visible windows' real sizes, a candidate scale `k`, the canvas width, and spacing, return `gridRows: [[Int]]` (window indices per visual row) and the total content height.
- [x] 1.4 Implement the uniform-scale solve: search `[kMin, kMax]` for the largest `k` whose wrapped grid height fits the canvas height; floor any card below `minCardSize`; if it overflows even at `kMin`, return the `kMin` layout flagged as vertically overflowing (D1, D5).
- [x] 1.5 Have the solve return a single result struct (chosen `k`, `gridRows`, per-card frames, total content size, overflow flag) consumed by both the view and the panel sizer (D2).

## 2. Model reshape

- [x] 2.1 In `Overlay/SwitcherModel.swift`, keep `rows = Spaces`/`currentRow = current Space`; add per-Space grid state derived from the solve: `gridRows`, `currentGridRow`, `col`, and keep `selectedIndex` (flat index into the current Space's windows) published for the existing highlight/live-preview/prefetch bindings (D3).
- [x] 2.2 Recompute the grid (call the solve) whenever the current Space's windows or the canvas size change; reset selection to `(0,0)` on Space change.
- [x] 2.3 Add horizontal move (within current visual row; clamp at row ends, wrap within row when `wrapAtEnds`) updating `col`/`selectedIndex` (D4).
- [x] 2.4 Add vertical move returning whether it crossed the grid edge: move `currentGridRow` and land on the row's first card; when already on the top row (up) or bottom row (down), report "edge crossed" without changing selection so the caller switches Space (D4).
- [x] 2.5 On Space switch, reset to `(0,0)` of the new Space's grid and recompute the solve.

## 3. View: wrapped real-proportion grid

- [x] 3.1 Rewrite `Overlay/SwitcherView.swift` to render `gridRows` as stacked rows of variable-size cards from the solved frames, replacing the single horizontal `ScrollView` of fixed cards.
- [x] 3.2 Render each card at its solved size with the thumbnail filling its proportion (no `.fit` letterboxing) and the app-icon placeholder when no thumbnail; vertically center cards within each row band (spec: mixed-height rows).
- [x] 3.3 Keep a single sliding highlight bound to `selectedIndex` (do NOT per-card animate — the Files `FilesRowHighlight` strobe landmine); the grid container may bubble-morph as a whole only.
- [x] 3.4 Drop the per-card title row; add a single highlighted-window icon+title centered beneath the grid, bound to `selectedIndex` (D6).
- [x] 3.5 Make the grid scroll vertically (keeping the highlight visible) only when the solve reports overflow; keep the per-Space slide transition (`.id(currentRow)` + `rowTransition`) and the Space indicator.

## 4. Panel sizing

- [x] 4.1 In `Overlay/OverlayController.swift`, compute the canvas target from the active screen's visible frame, run the solve, and size the panel to the actual grid height (hug, ≤ canvas), centered; clamp to the canvas height when overflowing (D5).
- [x] 4.2 Update `updateRow`/`updateColumn` plumbing to the reshaped model and re-layout the panel (animated) on Space change as today.

## 5. Navigation wiring

- [x] 5.1 In `App/AppCoordinator.swift`, route `gestureDidStep` (horizontal) to the model's within-row move.
- [x] 5.2 Route `gestureDidStepRow` (vertical) to the model's vertical move; only when it reports an edge crossing, perform the Space switch (with the existing `prefetchCurrentRow` + `refreshLiveSession` + `tickLivePreview`).
- [x] 5.3 Confirm the `GestureRecognizer` switcher odometer/axis-lock is untouched and still emits the same horizontal/vertical steps.

## 6. Onboarding demo + compatibility

- [x] 6.1 Update `Onboarding/FirstTouchWizardModel.swift` (`setRows`/`setColumn` usage) to the reshaped model so the demo compiles and still drives a sensible grid.
- [x] 6.2 Verify the synthetic Hub card lays out as one proportioned cell, icon-only, capture-excluded (D7 / spec).

## 7. Tests

- [x] 7.1 Unit-test the uniform-scale solve: one shared `k`; relative sizes preserved; `kMax` cap; `minCardSize` floor; overflow flag at `kMin`.
- [x] 7.2 Unit-test the flow-wrap: correct row breaks for given widths/canvas width; deterministic order.
- [x] 7.3 Unit-test grid navigation: horizontal clamps within a row; vertical moves rows and lands on the first card; edge crossing reported on top-up / bottom-down; entering a Space resets to `(0,0)`.

## 8. Build & verify

- [x] 8.1 `swift build` and `swift test` green (Core is MLX-free; the switcher lives here). — full package builds; 854 tests pass.
- [x] 8.2 Update `openspec/specs/switcher-overlay/spec.md` via the change's spec delta on archive; run `openspec validate switcher-window-grid`. — `openspec validate` passes; the spec delta is applied at archive (`/opsx:archive`).
- [x] 8.3 Hand-off note for the user to do the stable-signed `INSTALL=1 ./scripts/build-app.sh` and tune the feel constants (canvas fraction, `kMax`, `minCardHeight`, spacing) in-hand — see the implementation summary.
