## 1. Stopgap revert — un-regress off-Space focus (D0)

- [x] 1.1 Change `WindowService.swift:271` from `let stageManagerSafe = StageManager.isEnabled` to `let stageManagerSafe = !offSpaceHandshake && StageManager.isEnabled`
- [x] 1.2 Build and install: `INSTALL=1 ./scripts/build-app.sh`, then `open` the app
- [x] 1.3 RESULT: a lone off-Space window does NOT hold — `verify` PASSes at +180ms but focus is stolen by ~t+500ms. The revert is necessary but NOT sufficient (the thief is WindowManager, not a sibling window)
- [x] 1.4 CONFIRMED: every off-Space window deselects (lone + co-staged), resolving the discrepancy — the loss is real and universal for off-Space under Stage Manager, caused by the daemon's post-switch front-grab

## 2. Bug A — confirm heuristic data, then list off-Space windows without requiring AX (D2 step 1 → D1)

- [x] 2.1 Extend the off-Space probe block in `diagnosticReport()` to also print `alpha`, `bounds`, and `name` for each `brute=0` layer-0 regular-app off-Space window
- [x] 2.2 CONFIRMED: diag from a Space where Chrome's main window was off-Space showed `wid 16192 pid 1237 ... brute=0 axWin=0` (dropped from `final snapshot`)
- [x] 2.3 Threshold chosen from two diags: `alpha > 0 && min(width,height) ≥ 130` — real off-Space windows (incl. Stage Manager strip thumbnails) have min-dim ≥ 150; junk (toolbars, slivers, alpha-0 shadows) have min-dim ≤ 106 or alpha 0
- [x] 2.4 In `snapshot()`, hybrid listing gate: keep `isSwitchable(el)` when an element resolves; for the no-element off-Space case use `alpha > 0 && min(w,h) ≥ minOffSpaceDimension`
- [x] 2.5 Not needed — captures showed no `(pid, bounds)` shadow *duplicates*; the AX-less junk is thin bars / slivers / alpha-0, all rejected by the alpha + min-dim gate
- [x] 2.6 CONFIRMED: Chrome (and Chrome Remote Desktop) off-Space windows now appear, no duplicate/shadow entries; current-Space list unchanged (user: "chrome shows now")
- [x] 2.7 CONFIRMED Chrome off-Space raises on commit — but via the CACHED AX element + `kAXRaise` (§6), not the SkyLight `wid`+`psn` path this task originally assumed (that alone fronts the app without switching Spaces)

## 3. Confirmation gate — decide Bug B's course (D2 step 2)

- [x] 3.0a Add a passive multi-delay focus trace (`t+0.5/1/2/3.5s`, diagnostic-only, no raise change) — the +180ms watchdog `verify` PASSes for off-Space commits yet focus is still lost, so the loss is post-watchdog; the trace captures *when*
- [x] 3.0b CONFIRMED via the trace — NOT the co-staging singleton war: WindowManager (the Stage Manager daemon, pid 55186) grabs frontmost with `key=0` at ~t+500ms on EVERY off-Space raise (lone too — Finder, ASUS GlideX, Terminal) and holds it through t+3500ms; current-Space raises are immune. The +180ms watchdog PASSes because the steal lands after it
- [x] 3.1 Implement the fix candidate: for off-Space + Stage Manager, a single settle re-assert (`scheduleSettleReassert`) re-runs the off-Space focus sequence at t+700ms to reclaim front from WindowManager after the Space-switch settle
- [x] 3.2 CONFIRMED via the 01:27 diag: after the `settle-reassert t+700ms`, the t+1000/2000/3500ms traces PASS → the re-assert STICKS (later replaced by the faster polling hold-guard)
- [x] 3.4 VERDICT: STICKS — every off-Space commit holds through t+3500ms after the re-assert (one early sample re-stole at t+2000ms). The fixed 700ms re-assert left a ~200ms vacuum flash (steal ~t+500 → re-front t+700)

## 4. Bug B — finalize the off-Space focus hold (per the 3.4 verdict: STICK)

- [x] 4.1 Replaced the fixed 700ms re-assert with a ~60ms polling hold-guard (`scheduleNextHoldTick`/`offSpaceHoldTick`): re-fronts the instant the steal is detected (≈ one-poll flash), covers the late re-steal, bounded to 6 re-fronts / ~2.4s, bails on secure-input
- [x] 4.2 CONFIRMED via the 02:30 diag: hold-guard re-fronts at `@tick5` (~300ms), single `hold-refront`, holds through t+3500ms; rapid successive commits handled cleanly (token guard), no thrash/`gave-up`
- [x] 4.3 CONFIRMED via the 02:30 diag: current-Space commits (SM on) all PASS; Bug A Chromium listing intact; 117 unit tests green

## 6. Bug A part 2 — raise an off-Space window that has NO AX element (Chrome)

- [x] 6.0 Mechanism confirmed: an off-Space window with no AX element fronts the app but does NOT switch Spaces — `kAXRaiseAction(el)` is what drives the Space switch, and Chrome exposes no `el`; `activate()` then surfaces Chrome's current-Space window instead. (Apps whose off-Space window is `brute=1` switch fine.)
- [x] 6.1 Chose + implemented option 1 — direct Space switch via `CGSManagedDisplaySetCurrentSpace` (dlsym-gated, `SLS…` fallback, no-op if absent); display→Space mapping threaded through `SpaceModel.displayForSpace` → `WindowInfo.displayID`; switch fires only for off-Space windows with no AX element
- [x] 6.2 RESULT: REJECTED. Diag shows `directSwitch: true`, display UUID is valid (`37D8832A-…`, not `Main`), Chrome commits all PASS frontmost+key — BUT the Space does not visibly switch. `CGSManagedDisplaySetCurrentSpace` is neutered/auth-gated on Tahoe SIP-on for our unentitled process (matches the original design's rejection of it). Self-checked: the symbol and `SLS…`/`CGSShowSpaces`/`CGSAddWindowsToSpaces` variants all resolve, so it's a runtime auth gate, not a missing symbol
- [x] 6.3 Researched (workflow `off-space-chrome-raise-research`, multi-source + adversarial verify). Verdict: NAVIGATING to a no-AX off-Space window is impossible on Tahoe SIP-on (Space switch is Dock-only; CGSShowSpaces only "visual"; AXObserver-cached-element works but can't reach windows that were already off-Space before launch). The ONLY confirmed-working SIP-on/unentitled fix is to MOVE the window to the current Space via `SLSBridgedMoveWindowsToManagedSpaceOperation` (yabai #2788 on 26.4.1; shipped unentitled in DockDoor) — operates on CGWindowID, so it solves the brute=0 Chromium case. Tradeoff: it relocates the window to you rather than taking you to it.
- [x] 6.4 Removed the dead option-1 `CGSManagedDisplaySetCurrentSpace` branch from `focusSequence` (replaced with an explanatory note)
- [x] 6.5 DECISION: try option 2 (cached-element "navigate like other apps") FIRST; fall back to option 1 (bridged move) only if it can't reach Chrome
- [x] 6.6 Implemented option 2: persistent `elementCache` keyed by CGWindowID in `WindowService`, seeded (a) on app activation via `currentSpaceElements` and (b) opportunistically in `snapshot()`; used as a fallback for off-Space windows brute force can't find (both `snapshot()` listing and `resolveElement` raise); pruned to live windows each snapshot
- [x] 6.7 CONFIRMED on-device: off-Space Chrome navigates to its Space via the cached element (`02:30:09 commit pid=64276 wid=18461 cur=0 'Google Chrome'` → verify PASS → hold-refront → all traces PASS; user confirms "chrome now switches to its space"). Option 2 works — option 1 fallback (6.8) NOT needed
- [x] 6.8 Not needed — option 2 succeeded

## 5. Verify and wrap

- [x] 5.1 `swift test` green (117 passed)
- [x] 5.2 CONFIRMED via the 02:30 diag: mixed current-/off-Space commits (Finder, Code, Terminal, Chrome) — every `verify` PASSes, off-Space `hold-refront` then PASS, no `gave-up`
- [x] 5.3 Cleanup: removed the passive focus trace + the `diagnosticReport` off-Space AX-source probe + the dead option-1 plumbing (`CGSManagedDisplaySetCurrentSpace`, `offSpaceDirectSwitchSupported`, `directSwitch` diag field, `WindowInfo.displayID`, `SpaceModel.displayForSpace`); fixed now-inaccurate code comments. Build + 117 tests green; no dangling refs
- [x] 5.5 Reconciled OpenSpec artifacts (proposal/design/spec delta) + repo `README.md` (B0 history, A5 focus-vacuum, B3 landmines, B1 map) with what shipped. `openspec validate` passes
- [x] 5.4 Archived via `/opsx:archive` (artifacts complete, `openspec validate` passes, 117 tests green; the on-device confirmations above stand in for a separate `/opsx:verify`)
