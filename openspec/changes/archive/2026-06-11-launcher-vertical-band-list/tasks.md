## 1. Navigation model (`LauncherModel`)

- [x] 1.1 Rename the `Focus` semantics from `.headers` to `.bands` (the cursor is on the band list, not a top header row); update the doc comment to describe the left-list / right-grid layout.
- [x] 1.2 Rewire `stepVertical`: when focus is `.bands`, step the **active band** (up/down through `bands`, clamped) and re-apply that band's items; when focus is `.grid`, keep row stepping but **clamp at row 0** (no longer rise to the band strip).
- [x] 1.3 Rewire `stepHorizontal`: when focus is `.bands`, a step **toward the content** crosses to `.grid` (land on the home/first item) and a step away clamps; when focus is `.grid`, keep within-row stepping but, from **column 0**, a step toward the band list crosses back to `.bands`.
- [x] 1.4 Update `setBands` landing: multi-band → `focus = .bands` at the home band (nothing armed); single band → `focus = .grid` on the home cell (today's behavior). Expose `bandCount > 1` / single-band as needed by the view and controller.
- [x] 1.5 Update the focus query used by the gesture layer (`focusIsOnHeaders` → `focusIsOnBandList`) to mean "cursor is on the band list."
- [x] 1.6 Add/extend unit tests in the Core test target: vertical switches bands on `.bands`; right crosses into the grid at item 0; left from column 0 returns to `.bands`; row-0 up clamps; single-band lands on the first item; band/item stepping clamps (no wrap). Verify with `swift test`.

## 2. Layout metrics (`LauncherGridLayout`)

- [x] 2.1 Add band-column metrics (width of the left title list) and `minHeight` / `maxHeight` constants for the window; keep `columns = 6`, `cellWidth`, `cellHeight`, `spacing` unchanged.
- [x] 2.2 Replace the `tabsHeight`-based height math with a `min(max(taller-pane, minHeight), maxHeight)` helper that takes the band count and the active band's item count; drop the top `tabsHeight` strip from the grid container.

## 3. Launcher view (`LauncherView`)

- [x] 3.1 Replace the outer `VStack(tabs, Divider, grid)` with an `HStack(bandList, content)`; render `bandList` only when `bandCount > 1`.
- [x] 3.2 Implement the vertical band-title list reusing today's tab text styling (active emphasized, no new color swatches), driven by `model.bandNames` / `model.currentBand`, with a `ScrollViewReader` that keeps the **active** title vertically centered (`anchor: .center` on `currentBand` change).
- [x] 3.3 Keep the right-hand `grid` exactly as today (6 columns, scroll-to-selected on `selectedIndex`/`focus` change); ensure the band-list scroll target and the grid scroll target are driven by **independent** `onChange` sources so centering and scroll-to-item don't fight.
- [x] 3.4 Route the Clipboard band's master-detail into the **right** pane when it is the active band (band list stays on the left); leave the AI canvas as a full-surface replacement (unchanged).

## 4. Panel sizing (`LauncherOverlayController`)

- [x] 4.1 Update `layout()` to compute `width = bandColumnWidth + contentWidth` (content = grid width, or `ClipboardBandLayout` width when the active band is Clipboard; AI canvas unchanged) and `height = clamp(max(bandListHeight, contentHeight), minHeight, maxHeight)`; single-band uses `width = contentWidth` (no band column).
- [x] 4.2 Confirm band switches still animate the frame via the existing `layout(panel, animated:)` path without per-band height jitter (stable height; panes scroll inside).

## 5. Gesture layer (`GestureRecognizer` + `AppCoordinator`)

- [x] 5.1 In `GestureRecognizer`, move the coarse `launcherContextStepDistance` gate from the **horizontal** accumulator to the **vertical** accumulator when `launcherFocusIsOnBandList()` is true; make the horizontal accumulator always the fine item-step. Leave swipe detection, thresholds, carry, and edge detection untouched.
- [x] 5.2 Rename the delegate query `launcherFocusIsOnHeaders()` → `launcherFocusIsOnBandList()` and update `AppCoordinator` to forward it to `launcherOverlay.focusIsOnBandList`.
- [x] 5.3 Sanity-check edge auto-repeat: vertical-edge hold on the band list auto-repeats band switching with acceleration; horizontal-edge hold crosses into the grid then continues as item auto-repeat. No change to `edgeInterval`.

## 6. Clipboard band reconciliation

- [x] 6.1 In `LauncherModel.stepClipboardHorizontal`, change the **LEFT** action from "previous band" to "cross back to the band list (Clipboard title active)"; keep the deliberate **RIGHT** pin excursion and its latch/centre-return semantics.
- [x] 6.2 Keep horizontal auto-repeat suppressed in the Clipboard band (`setEdgeAutoScroll` already zeroes `hx` there); confirm vertical auto-repeat still scrolls entries.
- [x] 6.3 Update Clipboard navigation tests for the new LEFT semantic and unchanged pin behavior.

## 7. Verify, build, and sync

- [x] 7.1 `swift build` + `swift test` for the Core/logic targets; `xcodebuild` compile-verify the app/UI target (no install/sign per CLAUDE.md). _(swift build linked the app executable too; swift test: 559 passed, 0 failures.)_
- [ ] 7.2 Manual check (user-run stable-signed build): multi-band lands on the centered home title; one step right reaches the first item; left returns to the list; vertical scrolls bands with acceleration; single band lands on the first item; Clipboard extends and behaves per spec.
- [ ] 7.3 Run `/opsx:sync` to fold the delta into `openspec/specs/launcher-overlay/spec.md`, then `/opsx:verify` before archiving.
