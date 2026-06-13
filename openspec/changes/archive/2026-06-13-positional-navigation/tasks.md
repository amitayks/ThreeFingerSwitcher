## 1. Footprint plumbing (read what's already in the data)

- [x] 1.1 Add a footprint-spread accessor on `TouchFrame` (derive from `contacts[].position` — mean distance from `centroid`), returning `nil` when `contacts` is empty (the test-only `TouchFrame(testFingerCount:)` init) so callers apply the fixed fallback; also a `TouchFrame(testContactPoints:)` init for testing footprint scaling.
- [x] 1.2 Unit-test the spread accessor: a known multi-contact frame yields the expected spread; an empty-contacts frame yields `nil`; a single/degenerate contact yields zero (→ fallback).

## 2. Positional interpreter core (pure, testable)

- [x] 2.1 `Gesture/PositionalNavigator.swift`: pure per-axis `AxisZone` with inner/outer hysteresis (`feed(offset) -> stepDir` + `heldSign`), one step on outer-crossing while armed, re-arm inside inner, fast-flip handling. AppKit-free, fully unit-tested.
- [x] 2.2 `PositionalAnchor` (center + `scale = k·spread`, fixed fallback when spread unavailable/degenerate) + `PositionalNavigator` (anchor + two zones, `reanchor`, `feed`).
- [x] 2.3 Unit tests (`PositionalNavigatorTests`): out-and-back = one step; hold = step + sustained `heldSign`; return inside inner re-arms; footprint scaling; fixed fallback; re-anchor resets state + emits no step.

## 3. Recognizer — route launcher post-activation navigation through the interpreter

- [x] 3.1 `updateLauncher` active branch now feeds `launcherNav` (positional) instead of the odometer; the activation fling + latch/relax-to-two/end lifecycle are unchanged.
- [x] 3.2 Re-anchor on activation and on every contact-count change (the existing re-baseline branch), resetting per-axis state.
- [x] 3.3 `launcherEdgeChanged(dx:dy:)` repurposed as the held-in-zone signal (`updateHeldZones`); immediate first step via `emitItemStep`/`emitContextStep` (reverse settings honored).
- [x] 3.4 Item vs band coarseness = two outer thresholds from `launcherStepDistance` / `launcherContextStepDistance` (when on the band list), per D7.
- [x] 3.5 Recognizer tests migrated (`GestureRecognizerLauncherTests`): positional item/band steps + held signals; re-anchor emits no step; reversal honored.

## 4. Controller — eased dwell auto-repeat replaces edge-repeat

- [x] 4.1 `edgeInterval(tick:)` replaced by pure `RepeatCadence.interval(dwellElapsed:initialDelay:floor:rampTime:)` (ease-out, monotonic non-increasing, starts at initial delay, converges to floor); unit-tested (`PositionalNavigatorTests`, `ClipboardEdgeScrollTests`).
- [x] 4.2 Auto-repeat timer keyed to the held-in-zone signal; first step immediate, second after `initialRepeatDelay`, then `edgeDwellElapsed` accumulates and the interval follows the curve.
- [x] 4.3 All `edgeTick` cross-cutting concerns preserved (relayout, `syncFilesDrillState`/`syncFilesSearchInteractive`, `manageDwell`, clamp-doesn't-reset-dwell).
- [x] 4.4 Carve-outs kept: horizontal auto-repeat suppressed in Clipboard + Files; vertical kept; same eased curve on both axes everywhere.

## 5. Files navigator rides the same model

- [x] 5.1 `trackFilesDrill` relaxed posture now feeds `filesNav` (positional). Horizontal depth = deliberate discrete step (held dx suppressed, no auto-repeat); vertical highlight out-and-backs + auto-repeats via the held-in-zone signal (routed through `launcherEdgeChanged` → `model.stepVertical`, which the Files band already scrubs). Four-finger discard posture unchanged.
- [x] 5.2 "Very up → search" preserved: a held/repeated up-step at the top of the column still latches `focusSearchRequested` via `model.stepVertical` (both the manual `filesHighlight` and the edge-repeat path go through it).
- [x] 5.3 Files-drill tests migrated (`FilesDrillRecognizerTests`): positional depth/highlight out-and-back, single-push = one step, re-anchor emits no step.

## 6. Relative +1 → action-menu intent (generalized) — DEFERRED (documented follow-up)

- [~] 6.1 The relative-+1 mechanism exists and is verified via the **Files binding** (`filesOpenWith` — `count > baseline`, one-shot, re-anchor-relative). The surface-agnostic *seam* and a launcher-grid binding are **deferred**: the launcher action-menu **UI surface does not exist yet**, and adding a `+1`-lift intent to the launcher would change its load-bearing *lift-fires-armed-item* semantics with nothing to show. Documented in `CLAUDE.md`.
- [ ] 6.2 Launcher-grid action-menu binding + UI — **follow-up** (resolve the overlap-with-dwell-fire question from design Open Questions when the menu surface is built).
- [x] 6.3 The +1 detection is covered by the existing/ migrated Files-drill tests (relative +1 → Open-With, steady count → plain lift, one-shot, baseline 2→3 / 3→4).

## 7. AI canvas resolution → two fingers

- [x] 7.1 `trackCanvasResolution` re-keyed to **two** fingers; resolve excursion threshold = `canvasResolveThreshold` (0.12, above incidental scroll); down = commit, horizontal = discard, up = ignored.
- [x] 7.2 Sub-threshold two-finger motion scrolls (does not resolve); `launcherCanvasResolutionActive` entry/exit wiring unchanged; coordinator `launcherCanvasResolve` doc updated.
- [x] 7.3 Tests: two-finger discard/apply/up; sub-threshold (scroll) does not resolve; one-shot; lift re-arms (`GestureRecognizerLauncherTests`).

## 8. Tunables

- [x] 8.1 Positional tunables in `AppSettings` (decl + init + reset + `Defaults` + `Keys` + persist, live-applied): footprint factor, fallback scale, inner deadzone, initial repeat delay, repeat floor, ramp time.
- [x] 8.2 `launcherStepDistance`/`launcherContextStepDistance` repurposed as the item/band positional outer thresholds (offset units), defaults re-scaled; docs updated.
- [x] 8.3 Surfaced in the Hub **Launcher** page (`HubFeaturePages.swift`): re-scaled item/band sliders + a "Positional feel" section (deadzone, footprint sensitivity, first-repeat delay, fastest repeat, acceleration ramp). Persist + live-apply confirmed.

## 9. Shared core

- [x] 9.1 `PositionalNavigator` is a single shared type driven by both the launcher (`launcherNav`) and the Files drill (`filesNav`) — extracted by construction (design D1), each sub-state keeping its own resolution rules.
- [x] 9.2 No regression: the opening fling and the three-finger window switcher (`trackSwitcher`/`update`/`begin`) are untouched; latch / relax-to-two / re-baseline landmines preserved; full suite green.

## 10. Verification & docs

- [x] 10.1 `swift build` + `swift test` green — **826 tests** (new positional/zone/curve + migrated recognizer/files-drill tests; existing suite stays green).
- [x] 10.2 `swift build --product ThreeFingerSwitcher` compiles + links the MLX-linked app target (GemmaRuntime included); the MLX split is untouched.
- [x] 10.3 `CLAUDE.md` landmines updated: canvas resolution is **two-finger**; a new **anchored-positional navigation** section (position-not-travel, re-anchor, dwell-eased held-repeat not edge-triggered, +1 action-menu deferred).
- [x] 10.4 `README.md` updated: launcher anchored-joystick navigation, two-finger canvas resolve, `PositionalNavigator` in the repo map, test count 826.
- [x] 10.5 In-hand feel checklist handed to the user (see the apply summary) — to run on a stable-signed build.

## 11. Live trackpad preview + grouped controls (Hub)

- [x] 11.1 `TouchFrame.normalizedContactPoints: [CGPoint]` added (per-contact normalized positions; empty for count-only test frames).
- [x] 11.2 `HubContext.subscribeTrackpadTouch`/`unsubscribeTrackpadTouch` added and wired in `AppCoordinator` (`onHubTouchFrame`, called alongside `onWizardTouchFrame`); reuses the single running `TouchEngine` — no second listener, no new permission.
- [x] 11.3 `Hub/PositionalTrackpadPreview.swift`: subscribes on appear / unsubscribes on disappear; draws fingertips + center + deadzone + item (solid) / band (dashed) rings, scaled to the live footprint (fallback scale + neutral resting view + hint when no touch); reads `AppSettings` so it updates live.
- [x] 11.4 Integrated into the Launcher page: preview leads a **Positional feel** section; controls grouped **Center & margin (zone sizes)** + footprint and **Ease (hold-to-repeat curve)**; touch hooks threaded from `HubView`.
- [x] 11.5 `swift build` + `swift test` green (883); graceful with no touch; no new permission. Model/accessor unit-tested (`TrackpadPreviewTests`).
