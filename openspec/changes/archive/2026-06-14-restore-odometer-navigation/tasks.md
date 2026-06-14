## 1. Groundwork

- [x] 1.1 Review the working-tree state on this branch (uncommitted search-removal edits in `GestureRecognizer.swift`, `LauncherOverlayController.swift`, `FilesColumnController.swift`, `PlayerOverlayController.swift`) so the revert applies on top of them, not against `HEAD`.
- [x] 1.2 Capture the v0.11.0 reference for the recognizer/controller (`git show v0.11.0:…`) for `updateLauncher`, `updateEdges`, `edgeAxis`, `launcherEdgeChanged`, and the controller `edgeTimer`/`edgeInterval` as the restore target.

## 2. Restore the launcher odometer in the recognizer

- [x] 2.1 Restore `updateLauncher` to the v0.11.0 odometer: `stepAccumulator`/`stepAccumulatorY += Δcentroid`, emit item-steps at `launcherStepDistance` and context-steps at `launcherContextStepDistance` (coarser on the band list) with carry, both directions/axes.
- [x] 2.2 Restore `updateEdges` + `edgeAxis` (enter/exit hysteresis) emitting `launcherEdgeChanged(dx,dy)` on held-at-edge transitions; restore `clearEdges` on end/cancel.
- [x] 2.3 Restore re-baseline on every contact-count change (reset `stepAccumulator`/`stepAccumulatorY` + `lastCentroid`) in the launcher path; keep the latch / relax-to-two / end-below-two lifecycle intact.
- [x] 2.4 Remove the launcher `PositionalNavigator` usage: delete `launcherNav`, its `configure`/`reanchor` calls, the `feedLocked`/`applyAxisLock` wiring, and the commit-wedge / crossing-wedge / re-commit logic in `updateLauncher`.

## 3. Recreate Files-drill navigation as odometer

- [x] 3.1 Rewrite `trackFilesDrill` navigation as the 2-axis odometer: horizontal accumulator → depth descend/ascend steps, vertical accumulator → highlight steps, with carry and re-baseline on contact-count change.
- [x] 3.2 Emit a held-at-edge signal for the Files navigator on **both** axes (highlight + depth) so the controller auto-drills depth at the edge (uniform auto-repeat per the spec).
- [x] 3.3 Delete `filesNav` (the `PositionalNavigator` instance), `configureFilesNav`, and its axis-lock; preserve the drill modal entry/exit, the relative +1 Open-With latch, lift-to-open, 4-finger discard, and `rearmDrill`.

## 4. Recreate Player transport as odometer

- [x] 4.1 Rewrite `trackPlayer` navigation as the 2-axis odometer: horizontal accumulator → seek steps, vertical accumulator → volume steps, with carry and re-anchor on contact-count change (decide the seek/volume step distance — reuse `launcherStepDistance` or a player step).
- [x] 4.2 Emit a held-at-edge signal for the player on both axes so seek/volume auto-repeat at the edge.
- [x] 4.3 Delete `playerNav` (the `PositionalNavigator` instance) and `configurePlayerNav`; preserve tap-to-pause, the relative +1 action menu, 4-finger dismiss, and menu-open lift-selects.

## 5. Restore edge-triggered auto-repeat in the controllers

- [x] 5.1 Restore `LauncherOverlayController`'s `edgeTimer` + hyperbolic `edgeInterval(tick:acceleration:)` keyed to `launcherEdgeChanged`; preserve `edgeTick`'s cross-cutting work (relayout on band change, dwell reset, clamp-doesn't-reset-dwell).
- [x] 5.2 Delete the dwell-eased `RepeatCadence` path and any `setEdgeAutoScroll` dwell-curve wiring; keep Clipboard horizontal suppression, drop Files horizontal suppression (Files auto-drills both axes).
- [x] 5.3 Wire the Files (`FilesColumnController`) and Player (`PlayerOverlayController`) edge auto-repeat onto the same edge-triggered cadence.

## 6. Delete the positional navigator and tunables

- [x] 6.1 Delete `Sources/ThreeFingerSwitcher/Gesture/PositionalNavigator.swift` (`AxisZone`, `PositionalAnchor`, `RepeatCadence`) and `Tests/ThreeFingerSwitcherTests/PositionalNavigatorTests.swift`.
- [x] 6.2 Remove the `positional*` and axis-lock `Defaults`/`Keys`/`didSet` from `Settings/AppSettings.swift` (footprint factor, fallback scale, padding radius, edge margin, initial delay, floor, ramp, reArmBackoff, commit wedge, crossing wedge, recommit hysteresis, inner deadzone); keep `launcherStepDistance`/`launcherContextStepDistance` + the edge-repeat tunables. Confirm older settings still decode (stale keys ignored).
- [x] 6.3 Delete `Sources/ThreeFingerSwitcher/Hub/PositionalTrackpadPreview.swift` and `Tests/ThreeFingerSwitcherTests/TrackpadPreviewTests.swift`; remove the positional/axis-lock tuning group + preview from the Hub Launcher page, leaving the step-distance + edge-repeat controls.

## 7. Sibling in-progress change deltas

- [x] 7.1 Update `openspec/changes/files-band/specs/gesture-recognition/spec.md` and `.../specs/launcher-overlay/spec.md` to describe the Files navigator with the odometer model (depth/highlight travel steps, edge auto-drill) instead of positional.
- [x] 7.2 Update `openspec/changes/media-player/specs/gesture-recognition/spec.md` to describe the player transport with the odometer model (seek/volume travel steps, edge auto-repeat) instead of positional.

## 8. Tests

- [x] 8.1 Restore/keep the launcher recognizer odometer tests (item/band/row stepping with carry, re-baseline on count change, held-at-edge auto-repeat) in `GestureRecognizerLauncherTests.swift`.
- [x] 8.2 Migrate `FilesDrillRecognizerTests.swift` to assert odometer depth/highlight steps + both-axis edge auto-repeat.
- [x] 8.3 Migrate `PlayerDrillRecognizerTests.swift` to assert odometer seek/volume steps + edge auto-repeat.
- [x] 8.4 Remove positional/axis-lock assertions from `AppSettingsTests.swift` and any controller tests referencing the dwell-eased curve.

## 9. Docs and verification

- [x] 9.1 Revert the anchored-positional / axis-lock / dwell-eased landmines in `CLAUDE.md` and `README.md` to the odometer + edge-triggered auto-repeat model; keep the two-finger canvas-resolution note.
- [x] 9.2 `swift build` (Core) && `swift test` green — **874 tests, 0 failures**. (The MLX/MPVKit-linked app target's `xcodebuild` compile-check is the user's step — its dependency resolution is sandbox-gated — but all edits are Core-only and consume no removed app-facing API, so Core + tests fully cover the changed code.)
- [x] 9.3 `openspec validate restore-odometer-navigation --strict` passes; the change is ready to archive after the user confirms the in-hand feel on a stable-signed build.
