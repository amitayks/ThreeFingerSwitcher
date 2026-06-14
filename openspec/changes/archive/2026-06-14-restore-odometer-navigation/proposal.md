## Why

The anchored-positional "joystick" navigation (the `positional-navigation` + `launcher-aim-lock` changes) replaced the simple, well-loved **odometer** stepping that shipped through `v0.11.0`, and in hand it feels worse: a stateful per-surface navigator, directional axis-lock, padding-box + edge-margin acceleration, and a wedge-cone Hub preview added a lot of machinery and tuning surface without improving the feel. We want the v0.11.0 simplicity back — one stepping rule everywhere — and we want the band types added *after* v0.11.0 (the Files navigator and the Media player) to use that same odometer model rather than the positional one they were built on.

## What Changes

- **Restore the odometer for launcher navigation.** Post-activation launcher navigation goes back to signed centroid-travel accumulation per axis (`acc += Δcentroid`, emit a step each time it crosses the step distance, with carry), exactly as in `v0.11.0`. Horizontal = item move / band-list↔grid crossing; vertical = band switch (coarser step on the band list) or grid-row move.
- **Restore edge-triggered auto-repeat.** Holding the controlling contact at the physical trackpad edge (with enter/exit hysteresis) drives auto-repeat via the controller's `edgeTimer` on the hyperbolic `edgeInterval` ramp. The dwell-duration eased curve is removed.
- **Recreate the new bands' navigation in the odometer model.** The Files column navigator (`trackFilesDrill`) and the Media player (`trackPlayer`) keep their modal sub-states and all their *feature* semantics (Files: depth descend/ascend, highlight, +1-finger Open-With, lift-to-open, 4-finger discard; Player: seek, volume, tap-to-pause, +1-finger action menu, 4-finger dismiss) — but their *navigation* becomes the same 2-axis odometer with uniform edge auto-repeat on both axes (Files depth auto-drills at the edge like every other axis).
- **Remove the positional navigator and axis-lock entirely. BREAKING (feel).** Delete `Gesture/PositionalNavigator.swift` (`AxisZone`, `PositionalAnchor`, `RepeatCadence`), the per-surface `launcherNav` / `filesNav` / `playerNav`, and all axis-lock machinery (`applyAxisLock`, `feedLocked`, commit-wedge, recommit hysteresis, re-anchor, reArmBackoff, padding-box / edge-margin).
- **Remove the positional tunables and their Hub UI.** Delete the `positional*` settings (footprint factor, fallback scale, padding radius, edge margin, initial delay, floor, ramp, reArmBackoff, commit wedge, crossing wedge, recommit hysteresis, inner deadzone) and the `Hub/PositionalTrackpadPreview.swift` aim-wedge preview; the Hub Launcher page returns to the step-distance + edge-repeat tunables.
- **Out of scope (kept as-is):** the AI canvas's two-finger swipe-to-resolve grammar (4 = open/dismiss, 2 = act within) stays; the three-finger window switcher (already odometer) is untouched; no band/feature is removed — Files band, Media player, Clipboard, and AI band all remain.

## Capabilities

### New Capabilities
<!-- None — this reverts existing navigation behavior to a prior model. -->

### Modified Capabilities
- `gesture-recognition`: replace the anchored-positional interpreter (center + footprint scale + per-axis zone machine + directional axis-lock) with the **odometer** interpretation of post-activation navigation — signed centroid-travel accumulation with carry, per-axis step distances, re-baseline origin on every contact-count change; emit a held-**at-edge** signal (with sign + hysteresis) rather than a held-in-zone signal. Apply the same odometer to the Files-drill and Player sub-states. Opening/activation latches and the window switcher are unchanged.
- `launcher-overlay`: drive the launcher grid **and** the Files navigator from the odometer step signal; restore **edge-triggered** auto-repeat (`edgeTimer` + hyperbolic `edgeInterval`) in place of the dwell-duration eased curve, on both axes; the two-finger canvas resolution consumption is unchanged.
- `tunable-settings`: **REMOVE** the positional-model tunables; restore the step-distance (`launcherStepDistance`, `launcherContextStepDistance`) + edge-interval auto-repeat tunables as the navigation feel knobs.
- `configuration-hub`: **REMOVE** the positional tunables group and the aim-wedge live trackpad preview from the Hub Launcher page; surface the step-distance + edge-repeat tunables instead.

## Impact

- **Recognizer (`Gesture/GestureRecognizer.swift`):** restore `updateLauncher`/`updateEdges`/`edgeAxis` odometer + `launcherEdgeChanged` (held-at-edge) from `v0.11.0`; rewrite the navigation inside `trackFilesDrill` and `trackPlayer` as the 2-axis odometer while preserving their modal entry/exit, +1-finger latches, lift/tap resolution, and 4-finger discard/dismiss. Delete `Gesture/PositionalNavigator.swift` and the three navigator instances.
- **Controllers (`Overlay/LauncherOverlayController.swift`, `Files/FilesColumnController.swift`, `Overlay/PlayerOverlayController.swift`):** restore the `edgeTimer`/`edgeInterval` edge-triggered auto-repeat (replacing the dwell-eased `RepeatCadence`); the Files/Player edge auto-repeat routes through the same edge signal.
- **Settings (`Settings/AppSettings.swift`):** remove the `positional*` `Defaults`/`Keys`/`didSet`; keep `launcherStepDistance`/`launcherContextStepDistance` + the edge-repeat tunables.
- **Hub (`Hub/PositionalTrackpadPreview.swift`, the Launcher page):** delete the aim-wedge preview file and its page wiring.
- **Sibling in-progress changes:** the `files-band` and `media-player` change deltas (`specs/gesture-recognition`, `specs/launcher-overlay`) currently describe positional navigation for their surfaces — update them in-place to the odometer model so they don't re-introduce the positional language when archived.
- **Tests:** delete `PositionalNavigatorTests.swift` and `TrackpadPreviewTests.swift`; restore/keep the odometer recognizer tests (item/band/row stepping with carry, re-baseline on count change, edge-held auto-repeat); migrate the Files-drill and Player recognizer tests to assert odometer steps + edge auto-repeat. Verified via `swift build` / `swift test` (MLX-free Core); the MLX/`GemmaRuntime` split is untouched.
- **Docs (`CLAUDE.md`, `README.md`):** revise the anchored-positional / axis-lock / dwell-eased landmines back to the odometer + edge-repeat model; the two-finger canvas-resolution note stays.
