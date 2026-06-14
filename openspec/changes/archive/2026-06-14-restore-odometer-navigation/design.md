## Context

`v0.11.0` (`9229e2a`) is the last release with the **odometer** navigation: `GestureRecognizer.updateLauncher` accumulates signed centroid travel per axis (`acc += Δcentroid`), emits a step each time the accumulator crosses the per-axis step distance (with carry), and `LauncherOverlayController` auto-repeats by detecting the controlling contact **held at a physical trackpad edge** (`launcherEdgeChanged` → `edgeTimer` → hyperbolic `edgeInterval`). It is ~30 lines, two tunables, one ramp.

The three commits after v0.11.0 replaced this with an **anchored-positional joystick**: `Gesture/PositionalNavigator.swift` (`AxisZone` position-tracking/out-and-back + `PositionalAnchor` + `RepeatCadence` dwell-eased curve), three per-surface navigator instances (`launcherNav`, `filesNav`, `playerNav`), directional **axis-lock** (`applyAxisLock`/`feedLocked`, commit wedge, crossing wedge, re-commit hysteresis, per-axis re-anchor), padding-box + edge-margin acceleration, ~70 `positional*` tunables, and the `Hub/PositionalTrackpadPreview.swift` aim-wedge preview. The Files navigator and Media player — added in the same span — were built on this positional model.

The user finds the positional feel worse and wants the v0.11.0 simplicity back, with the new bands (Files navigator, Media player) navigating by the **same** odometer rather than the positional model. The window switcher already uses the odometer and is untouched; the AI canvas's two-finger swipe-to-resolve grammar stays.

The recognizer and these controllers also have uncommitted edits on this branch (the Files-band search removal); this work lands on the same branch and must merge cleanly with those edits.

## Goals / Non-Goals

**Goals:**
- Restore the v0.11.0 odometer for post-activation launcher navigation (signed travel accumulation + carry, per-axis step distance, re-baseline on contact-count change) and edge-triggered auto-repeat (held-at-edge + hyperbolic `edgeInterval`).
- Recreate the Files navigator (`trackFilesDrill`) and Media player (`trackPlayer`) **navigation** in the same 2-axis odometer, with **uniform edge auto-repeat on both axes** (Files depth auto-drills at the edge), while preserving every feature behavior of those surfaces.
- Delete the positional navigator, the three navigator instances, all axis-lock machinery, the positional tunables, and the aim-wedge Hub preview.
- Keep the result MLX-free and `swift test`-verifiable; leave the `GemmaRuntime`/app split untouched.

**Non-Goals:**
- No change to the AI canvas resolution grammar (stays two-finger: down = apply, horizontal = discard).
- No change to opening/activation (the odometer horizontal fling), the three-finger window switcher, or the relax-to-two / re-baseline lifecycle.
- No removal of any band or feature — Files band, Media player, Clipboard band, AI band all stay, with their modal sub-states (`filesDrillActive`/`trackFilesDrill`, `playerActive`/`trackPlayer`), +1-finger Open-With / action menu, lift-to-open / tap-to-pause, and 4-finger discard / dismiss intact.
- No new haptics, no new permission.

## Decisions

### D1 — One odometer mechanic, three emit-closures
All three reverted surfaces share the identical v0.11.0 accumulator (`acc += Δcentroid; while |acc| ≥ step: acc ∓= step; emit(sign)`), differing only in what a step *does*:

| Surface       | horizontal step →              | vertical step →                   |
|---------------|--------------------------------|-----------------------------------|
| Launcher      | item move / rail↔grid cross    | band switch (coarser) / grid row  |
| Files drill   | depth descend / ascend         | highlight up / down               |
| Player        | seek                           | volume                            |

The recognizer holds the launcher accumulators (restored `updateLauncher`) and per-surface accumulators inside `trackFilesDrill` / `trackPlayer`. *Alternative:* keep a small shared "odometer" helper struct. Rejected for v1 — the accumulate-and-emit loop is ~6 lines; a struct adds indirection for no real reuse win and risks re-introducing the per-surface-object complexity we're removing. Inline it, matching v0.11.0.

### D2 — Restore the held-at-edge signal + controller edge-repeat verbatim
Re-introduce `updateEdges`/`edgeAxis` (enter/exit hysteresis) emitting `launcherEdgeChanged(dx,dy)` on the held-at-**edge** transition, and restore `LauncherOverlayController`'s `edgeTimer` + hyperbolic `edgeInterval(tick:acceleration:)`. The dwell-eased `RepeatCadence` is deleted. The controller's existing cross-cutting `edgeTick` work (relayout on band change, dwell reset, clamp-doesn't-reset-dwell) is preserved on the restored timer. *Alternative:* keep the dwell-eased curve but drive it off the edge signal. Rejected — the user wants the v0.11.0 feel, ramp included.

### D3 — Files/Player edge auto-repeat routes through the same edge signal; both axes for Files
Per the user's "uniform auto-repeat" decision, the Files navigator auto-repeats on **both** axes (highlight + depth), so holding depth at the edge auto-drills — unlike the current spec which suppresses Files horizontal. Clipboard keeps its horizontal suppression (horizontal there is the deliberate pin / return-to-band action). The Files/Player controllers consume the same `launcherEdgeChanged`-style edge signal (or a per-surface equivalent) on the same `edgeTimer` cadence. *Alternative:* deliberate one-step-per-stroke depth. Rejected by the user.

### D4 — Keep the modal sub-states and finger-count intents; revert only the feel
`filesDrillActive`/`trackFilesDrill`, `playerActive`/`trackPlayer`, the relative +1-finger Open-With / action-menu, lift-to-open / tap-to-pause, 4-finger discard / dismiss, and `rearmDrill` are **feature plumbing**, not navigation feel — they stay. Only the navigation *interpretation* inside them changes from positional to odometer. The "Relative +1-finger action-menu intent" spec requirement is untouched (it is finger-count semantics, orthogonal to odometer vs positional). *Alternative:* fold Files navigation back into `updateLauncher`. Rejected — the drill has depth/Open-With/lift semantics the launcher grid lacks; the sub-state is the right seam.

### D5 — Delete positional code and tunables; ignore stale persisted keys
Delete `Gesture/PositionalNavigator.swift`, `Hub/PositionalTrackpadPreview.swift`, `PositionalNavigatorTests.swift`, `TrackpadPreviewTests.swift`, the `launcherNav`/`filesNav`/`playerNav` fields, `applyAxisLock`/`feedLocked`/`configureFilesNav`/`configurePlayerNav`, and the `positional*` `Defaults`/`Keys`/`didSet` in `AppSettings`. Persisted `positional*`/axis-lock keys left in a user's store are simply not read — older settings still decode and the launcher opt-in is unaffected (no migration code, no reset). *Alternative:* a migration that strips the keys. Rejected — unread keys are harmless; a migration is extra risk for no benefit.

### D6 — Update the sibling in-progress change deltas in place
`files-band` and `media-player` are in-progress (not archived), and their `specs/gesture-recognition` / `specs/launcher-overlay` deltas describe positional navigation for their surfaces. Edit those deltas in place to the odometer model so they don't re-introduce positional language when archived. This change's own spec deltas cover only the four **main** specs. *Alternative:* leave them and fix at archive time. Rejected — they'd conflict with the reverted main specs and silently reassert positional behavior.

## Risks / Trade-offs

- **Merge tangle with the branch's uncommitted search-removal edits** (same files: `GestureRecognizer`, `LauncherOverlayController`, `FilesColumnController`, `PlayerOverlayController`). → Read the working-tree state first; apply the revert on top of the current edits rather than against `HEAD`, and re-run `swift test` after each file.
- **Losing precise positional placement.** The joystick let the cursor jump several steps in one frame and hold to accelerate from rest; the odometer requires physical travel + an edge hold. → This is the explicitly requested feel; the edge ramp restores fast traversal. Tune `edgeInterval` if the floor feels slow.
- **Files depth auto-drill overshoot.** Uniform edge auto-repeat on depth can over-drill folders if held. → Same clamp-and-dwell rules as every axis; a clamped step doesn't reset dwell. Validate in-hand.
- **Stale `positional*` keys / dead Hub controls.** Removing settings could leave dangling references in the Hub page or `AppSettingsTests`. → Compile-driven: `swift build`/`swift test` surface every reference; remove the Hub Launcher-page positional group and the positional settings tests.
- **Docs drift.** `CLAUDE.md` / `README.md` document the positional/axis-lock/dwell-eased model as landmines. → Revert those sections to the odometer + edge-repeat model; keep the two-finger canvas-resolution note.

## Migration Plan

Additive-free revert behind the existing launcher opt-in; no data migration (stale keys ignored). Sequence: (1) restore recognizer `updateLauncher`/`updateEdges`/`edgeAxis` + `launcherEdgeChanged`; (2) rewrite `trackFilesDrill` / `trackPlayer` navigation as odometer + edge signal; (3) restore controller `edgeTimer`/`edgeInterval`, delete dwell-eased `RepeatCadence`; (4) delete `PositionalNavigator.swift` + the nav instances + axis-lock; (5) delete positional tunables + Hub preview; (6) update sibling `files-band` / `media-player` deltas; (7) update docs; (8) migrate/restore tests. **Verify** with `swift build` / `swift test` (Core) and `xcodebuild` compile-check for the MLX-linked target; in-hand feel tuning on a stable-signed build (user-run — the agent shell can't sign). **Rollback** is reverting this change; the opening/activation and window-switcher paths are untouched throughout.

## Open Questions

- **Edge-repeat tunable defaults.** Restore the exact v0.11.0 `edgeInterval` constants (0.18s → 0.03s) and edge enter/exit zones, or re-tune now? Default: restore v0.11.0 values, tune in-hand later.
- **Player seek/volume granularity.** What travel distance maps to one seek/volume step (reuse `launcherStepDistance`, or a player-specific step)? Resolve when wiring `trackPlayer`.
- **Shared edge signal vs per-surface.** Whether the Files/Player edge auto-repeat reuses the launcher `launcherEdgeChanged` delegate path or a small parallel signal — decide during implementation to keep the controllers clean.
