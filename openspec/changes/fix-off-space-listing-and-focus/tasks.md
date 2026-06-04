## 1. Stopgap revert — un-regress off-Space focus (D0)

- [x] 1.1 Change `WindowService.swift:271` from `let stageManagerSafe = StageManager.isEnabled` to `let stageManagerSafe = !offSpaceHandshake && StageManager.isEnabled`
- [x] 1.2 Build and install: `INSTALL=1 ./scripts/build-app.sh`, then `open` the app
- [x] 1.3 RESULT: a lone off-Space window does NOT hold — `verify` PASSes at +180ms but focus is stolen by ~t+500ms. The revert is necessary but NOT sufficient (the thief is WindowManager, not a sibling window)
- [x] 1.4 CONFIRMED: every off-Space window deselects (lone + co-staged), resolving the discrepancy — the loss is real and universal for off-Space under Stage Manager, caused by the daemon's post-switch front-grab

## 2. Bug A — confirm heuristic data, then list off-Space windows without requiring AX (D2 step 1 → D1)

- [x] 2.1 Extend the off-Space probe block in `diagnosticReport()` to also print `alpha`, `bounds`, and `name` for each `brute=0` layer-0 regular-app off-Space window
- [ ] 2.2 Capture Diagnostics from a Space where Chrome's main window is off-Space; read `/tmp/tfs-cross-space-diag.txt` and confirm Chrome's window shows `brute=0 axWin=0`
- [x] 2.3 Threshold chosen from two diags: `alpha > 0 && min(width,height) ≥ 130` — real off-Space windows (incl. Stage Manager strip thumbnails) have min-dim ≥ 150; junk (toolbars, slivers, alpha-0 shadows) have min-dim ≤ 106 or alpha 0
- [x] 2.4 In `snapshot()`, hybrid listing gate: keep `isSwitchable(el)` when an element resolves; for the no-element off-Space case use `alpha > 0 && min(w,h) ≥ minOffSpaceDimension`
- [x] 2.5 Not needed — captures showed no `(pid, bounds)` shadow *duplicates*; the AX-less junk is thin bars / slivers / alpha-0, all rejected by the alpha + min-dim gate
- [ ] 2.6 Build/install; confirm Chrome (and Chrome Remote Desktop) off-Space windows now appear in the switcher, with no duplicate/shadow entries; confirm current-Space list is unchanged
- [ ] 2.7 Confirm an off-Space Chrome window (nil AX element) raises correctly on commit via the SkyLight `wid`+`psn` path

## 3. Confirmation gate — decide Bug B's course (D2 step 2)

- [x] 3.0a Add a passive multi-delay focus trace (`t+0.5/1/2/3.5s`, diagnostic-only, no raise change) — the +180ms watchdog `verify` PASSes for off-Space commits yet focus is still lost, so the loss is post-watchdog; the trace captures *when*
- [x] 3.0b CONFIRMED via the trace — NOT the co-staging singleton war: WindowManager (the Stage Manager daemon, pid 55186) grabs frontmost with `key=0` at ~t+500ms on EVERY off-Space raise (lone too — Finder, ASUS GlideX, Terminal) and holds it through t+3500ms; current-Space raises are immune. The +180ms watchdog PASSes because the steal lands after it
- [x] 3.1 Implement the fix candidate: for off-Space + Stage Manager, a single settle re-assert (`scheduleSettleReassert`) re-runs the off-Space focus sequence at t+700ms to reclaim front from WindowManager after the Space-switch settle
- [ ] 3.2 Reproduce off-Space switches on the new build, Write Diagnostics, and read the trace at t+1000/2000/3500ms (after the t+700ms `settle-reassert` line)
- [x] 3.4 VERDICT: STICKS — every off-Space commit holds through t+3500ms after the re-assert (one early sample re-stole at t+2000ms). The fixed 700ms re-assert left a ~200ms vacuum flash (steal ~t+500 → re-front t+700)

## 4. Bug B — finalize the off-Space focus hold (per the 3.4 verdict: STICK)

- [x] 4.1 Replaced the fixed 700ms re-assert with a ~60ms polling hold-guard (`scheduleNextHoldTick`/`offSpaceHoldTick`): re-fronts the instant the steal is detected (≈ one-poll flash), covers the late re-steal, bounded to 6 re-fronts / ~2.4s, bails on secure-input
- [ ] 4.2 Confirm on-device: off-Space focus now lands with a barely-perceptible (or no) flash; check no thrash/flicker on rapid switching
- [ ] 4.3 Confirm current-Space (SM on and off) and the Bug A Chromium listing are still correct (no regression)

## 6. Bug A part 2 — raise an off-Space window that has NO AX element (Chrome)

- [x] 6.0 Mechanism confirmed: an off-Space window with no AX element fronts the app but does NOT switch Spaces — `kAXRaiseAction(el)` is what drives the Space switch, and Chrome exposes no `el`; `activate()` then surfaces Chrome's current-Space window instead. (Apps whose off-Space window is `brute=1` switch fine.)
- [ ] 6.1 Choose the no-AX Space-switch approach (decision pending — see options)
- [ ] 6.2 Implement + on-device confirm: committing to off-Space Chrome switches to its Space and shows that window

## 5. Verify and wrap

- [ ] 5.1 Run `swift test` green
- [ ] 5.2 Re-capture a clean focus log across mixed current-/off-Space and lone/co-staged commits; confirm every `verify` PASSes and no `gaveUp`
- [ ] 5.3 Remove or gate the temporary probe additions from 2.1 if they are not wanted in the shipped diagnostics
- [ ] 5.4 Run `/opsx:verify` for this change, then archive
