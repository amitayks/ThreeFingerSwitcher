> One mechanic — the launcher's dwell-to-arm — wired into the Files drill + its sub-columns. Reuses `DwellArmDriver` + `model.armed` + `dwellToArmDuration`; the recognizer is untouched. MLX-free Core + app; `swift build` / `swift test` verify the logic + state resets, `xcodebuild` compile-verifies the app target, and the live haptic / ring / deliver are user run-verify. Depends on `add-files-band-actions` (the resolutions being gated).

## 1. Dwell-to-arm wiring on the Files drill

- [x] 1.1 Files arm state reuses the launcher semantics. The Files band view is mutually exclusive on-screen with the launcher grid, so the **shared** `model.arming`/`armed`/`armingToken`/`dwell` + `beginArming`/`setArmed`/`disarm` are reused directly (no dedicated Files flags); the restart **decision** is the pure, identity-keyed `FilesDwellArming` (`Overlay/FilesDwellArming.swift`), and the timer is `LauncherOverlayController`'s existing `dwellDriver` (no second timer). New `LauncherOverlayController.filesManageDwell()` / `filesRearmDwell()`.
- [x] 1.2 **Restart the dwell** on every Files highlight/depth/column move: `manageDwell()` now routes to `filesManageDwell()` while a Files surface is engaged (covers the cross-in landing + the edge-tick auto-repeat reset — so auto-drill never arms mid-scroll); the coordinator calls `filesManageDwell()` after `filesHighlight`/`filesDepth`; and the model's async re-list fires `onFilesProjectionChanged` → `filesManageDwell()`. Arm fires the existing `arm()` (`setArmed` + `DwellArmDriver.hapticTick()`).
- [x] 1.3 **Gate the committing lifts:** a single `guard launcherOverlay.model.armed else { hide() }` at the top of `filesOpen()` (covers deliver/open + picker-app + menu-row commits) and before `filesOpenWith()` opens the menu; an unarmed lift dismisses. The recognizer (`resolveFilesDrillLift`/`resolveFilesDrillExcursion`) is unchanged.
- [x] 1.4 The `+1`-finger morph does **not** restart the dwell — the recognizer's count-change re-baseline already emits no `filesHighlight`/`filesDepth` step, so `filesManageDwell` isn't called and the identity is unchanged (`FilesDwellArming` → `.keep`), preserving the arm; **entering** the menu (`filesOpenWith`) calls `filesManageDwell()` → a fresh dwell on row 0. Covered by `FilesDwellArmingTests.testSameIdentityKeeps…`.
- [x] 1.5 **Discard stays ungated:** `filesDiscard()` has no `armed` gate — it backs out / dismisses armed or not; `cancelPending()` still never terminates a running app. Back-outs recharge the dwell on the surface they land on.

## 2. Sub-column gating (navigator + all sub-columns)

- [x] 2.1 Re-charge on every sub-column move: the coordinator's `filesHighlight` (which dispatches `filesActionMenuMove` / `filesPickerMove` / folder highlight) ends with one `filesManageDwell()`; `FilesDwellArming` keys sub-columns on their row index (`menu:N` / `picker:N`) so each scrub restarts.
- [x] 2.2 Gate the sub-column commits: the `filesOpen()` top gate covers the picker-app and menu-row commits; "Open in ▸" descending into the app grid (`presentOpenWithPicker`) recharges so the landing app must itself be dwelled.
- [x] 2.3 **Arm-state hygiene:** natural transitions (enter menu, descend to grid, discard back-out) change identity → restart from zero; the one in-place re-arm (a delivery that failed and kept the navigator open) calls `filesRearmDwell()` (resets the identity → forced fresh dwell); leaving every Files surface resets `FilesDwellArming` in `manageDwell`. Covered by `FilesDwellArmingTests.testResetForces…` / `testSubColumnTransitions…`.

## 3. Charge-ring visual

- [x] 3.1 The folder-list highlight (`FilesRowHighlight`) **already** took `token`/`armed`/`dwell` and renders the linear-charge → ease-out-arm pill; it now animates because the drill arms. No new visual primitive, no per-row spring (the morph landmine is untouched).
- [x] 3.2 The sub-column popups (action menu + Open-With / app grid) now render the **same** charging `FilesRowHighlight` (was the static `OpenWithRowHighlight`, now removed) driven by `model.armingToken`/`armed`/`dwell` — so the ring is present on every Files lift-to-commit surface.

## 4. Verify

- [x] 4.1 `swift build` green (Core + GemmaRuntime + the app executable all compile/link locally — Metal toolchain present, so `swift build` covers the app target). `swift test` green — **1020 tests, 0 failures** (7 new `FilesDwellArmingTests` covering: landing→restart, same-identity→keep [the `+1`-finger-preserves-arm case], move→restart, empty→disarm, start-on-nothing→keep, sub-column transitions→restart, reset→forced restart).
- [x] 4.2 `openspec validate add-files-band-dwell-arm --strict` passes.
- [ ] 4.3 **User run-verify** in a stable-signed build (`INSTALL=1 ./scripts/build-app.sh`): scrub-and-lift fast on a file → **dismisses, no delivery**; rest on it past the dwell → haptic + ring locks → lift **delivers**; `+1`-finger after arming → menu opens; scrub-and-`+1`-lift fast → dismisses; inside the menu, a row commits only after its own dwell; the four-finger discard backs out armed or not; auto-drill at the edge never arms mid-scroll.
