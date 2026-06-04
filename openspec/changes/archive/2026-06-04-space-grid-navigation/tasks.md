## 1. Settings

- [x] 1.1 `AppSettings`: add `rowStepDistance` (default ≈0.12, > `stepDistance`) and `reverseVerticalDirection` (Bool); persist + defaults + reset.
- [x] 1.2 `SettingsView`: add a row-step-distance slider and a reverse-vertical toggle.

## 2. Gesture recognizer (2D)

- [x] 2.1 Add `gestureDidStepRow(_ direction: Int)` to `GestureRecognizerDelegate`.
- [x] 2.2 After activation, stop ignoring vertical: maintain `stepAccumulatorY` from centroid Δy alongside the horizontal accumulator; keep activation gated on horizontal dominance (fresh vertical still yields).
- [x] 2.3 Emit a row step when `|stepAccumulatorY| ≥ rowStepDistance` (carry/remainder); reversal steps back; apply `reverseVerticalDirection` and normalize the OMS y sign so up = next by default.

## 3. Grid model

- [x] 3.1 `SwitcherModel`: add `rows: [[WindowInfo]]`, `currentRow`, `selectedColumn`, and per-row Space label/index; make `windows`/`selectedIndex` computed from them. Add `setRows(rows:startRow:column:)` and row/column mutators.

## 4. Overlay

- [x] 4.1 `SwitcherView`: render the current row's cards (existing strip) plus a row indicator (dots or "Space N / M"); animate vertical row swaps; preserve adaptive width + highlight.
- [x] 4.2 `OverlayController`: size/position using the current row; expose `show(rows:startRow:column:)`, `updateColumn(_:)`, `updateRow(_:)`.

## 5. Wiring

- [x] 5.1 `AppCoordinator.gestureDidActivate`: snapshot → group by `spaceID` (Space order, non-empty rows) → start on the `isOnCurrentSpace` row → show; prefetch the visible row's thumbnails.
- [x] 5.2 Implement `gestureDidStep` (column within row, clamp/wrap) and `gestureDidStepRow` (row clamp/wrap per setting; reset column to 0; prefetch the new row).
- [x] 5.3 `gestureDidCommit`: raise `rows[currentRow][selectedColumn]`.

## 6. Build & on-device test/tuning

- [x] 6.1 `swift build` clean; assemble bundle.
- [x] 6.2 Up/down switches Space-rows reliably across multiple Spaces; left/right scrubs within a row.
- [x] 6.3 A fresh three-finger up/down still opens Mission Control / App Exposé.
- [x] 6.4 Commit raises the highlighted window and switches to its Space once.
- [x] 6.5 Tune `rowStepDistance` so horizontal scrubbing never accidentally flips rows but deliberate up/down feels responsive.
