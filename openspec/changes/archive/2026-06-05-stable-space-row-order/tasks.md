## 1. Carry the Mission Control order index on the window model

- [x] 1.1 Add `let spaceIndex: Int` to `WindowInfo` (`Sources/ThreeFingerSwitcher/Windows/WindowInfo.swift`), documented as the Mission Control order index (lower = earlier/leftmost).
- [x] 1.2 In `WindowService.snapshot()` (`Sources/ThreeFingerSwitcher/Windows/WindowService.swift`), set `spaceIndex: model.indexBySpace[placement.space] ?? Int.max` on the constructed `WindowInfo`.
- [x] 1.3 In `WindowService.legacySnapshot()`, set `spaceIndex: 0` on the constructed `WindowInfo`.

## 2. Order rows by Mission Control order in the grouping

- [x] 2.1 In `SpaceGrouping.group()` (`Sources/ThreeFingerSwitcher/Windows/SpaceGrouping.swift`), track each bucket's `spaceIndex` (from any window in the bucket) alongside its `isCurrent` flag.
- [x] 2.2 Replace the current-first comparator with a sort by `spaceIndex` ascending.
- [x] 2.3 Compute `startRow` as the sorted position of the first current bucket (else 0).
- [x] 2.4 Set each row's label to its true Space number (`spaceIndex + 1`) instead of the row position.

## 3. Tests

- [x] 3.1 Add a `spaceIndex` parameter to the `makeWindow` helper in `Tests/ThreeFingerSwitcherTests/SpaceGroupingTests.swift`.
- [x] 3.2 Rewrite ordering assertions: rows sorted by `spaceIndex`, current Space no longer forced first.
- [x] 3.3 Add/adjust `startRow` assertions so it points at the current Space's position (not always 0), including a case where the current Space is not the lowest index.
- [x] 3.4 Update label assertions to the true-Space-number semantics.
- [x] 3.5 Keep coverage for empty input, single Space, in-bucket order preservation, nil-spaceID (legacy key-0) bucket, and no-current-Space → `startRow` 0.
- [x] 3.6 Verify `Tests/ThreeFingerSwitcherTests/SwitcherModelTests.swift` does not hard-code `startRow == 0`; adjust if it does. (Already exercises non-zero startRow; only the `makeWindow` helper needed the new field. Also updated the `HarnessTests` grouping smoke test.)

## 4. Verify

- [x] 4.1 Run `swift test`; confirm `SpaceGroupingTests` and the full suite pass. (118 tests, 0 failures.)
- [x] 4.2 Manual check on a multi-Space setup: on Space 2 of 3, the overlay highlights the middle row; swipe down → Space 1, swipe up → Space 3. _(Confirmed by the user after rebuilding the app bundle via `scripts/build-app.sh`.)_
- [x] 4.3 Manual check of stability: move to another Space and reopen — each Space keeps its row position; close the last window on a Space and confirm that row drops out on next open. _(Confirmed by the user.)_
- [x] 4.4 Run `openspec validate stable-space-row-order`. (Valid.)
