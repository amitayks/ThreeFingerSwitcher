> Decomposed for a workflow fan-out: §1–§2 are the shared substrate (do first), §4–§8 are **one per page** and independent once the substrate lands, §9 is the cross-cutting binding consumption, §10 verifies.

## 1. Pose driver (pure Core)

- [x] 1.1 Lift `FirstTouchWizardModel.attractPose` into MLX-free Core as `GesturePose.pose(phase:fingers:axis:)`, parameterized by **finger count** (2/3/4 → number of fingertip offsets) and **axis** (`.horizontal` ping-pong, `.vertical`, `.scripted([keyframe])` for hover-demo AND the band pages' multi-step open→band→in-surface journey). Keep it pure/`nonisolated`.
- [x] 1.2 Repoint the wizard's `attractPose` call at the shared function (no behavior change to onboarding); keep/port the existing bounds/shape unit tests.
- [x] 1.3 Unit tests: 2/3/4-finger poses stay in `[0.05, 0.95]`; horizontal vs vertical centroid travel; a scripted excursion runs start→end→loop.

## 2. Preview substrate (Hub + live touch)

- [x] 2.1 Add `HubGesturePreview` (`Hub/`): a live overlay miniature slot over a generalized `FingerDotsPad`, with the three states — **attract** (loops the bound gesture), **hover-demo** (loops a candidate excursion), **rehearse** (real touch). Reuse `WizardMotion` (`PulseHalo`/`BreathingGlowBackdrop`/`ShimmerSweep`).
- [x] 2.2 Generalize/relocate `FingerDotsPad` so it is shared by the wizard and the Hub (count-agnostic already; expose finger count + live flag).
- [x] 2.3 Hub-local live-touch subscription: subscribe to the `TouchEngine` feed only while a preview is on screen/focused; gate to **≥2 fingers**; map contacts → dots + drive the miniature.
- [x] 2.4 **Rehearse-does-not-fire isolation:** while a preview is rehearsed, suppress real gesture handling (reuse the `wizardOwnsGestures` precedent); resume on focus-loss / lift. Verify a Hub rehearse never opens the launcher or fires a command.

## 3. Switch-style master toggle + a previewed-section scaffold

- [x] 3.1 Add a `HubFeatureHeader` (or extend `HubPage`) that renders the `HubGesturePreview` then the Overview-style master toggle row (icon + title + subtitle + `.switch`, mirroring `OverviewPage.featureRow`) directly beneath it.
- [x] 3.2 Leave all secondary controls (`LabeledSlider`/`Picker`/buttons) untouched — only the leading master enable is restyled.

## 4. Switcher page (one-per-page)

- [x] 4.1 Lead `SwitcherPage` with the preview (3-finger ⇄ for windows; 3-finger ⇅ for Spaces) + switch-style `enabled` toggle.
- [x] 4.2 Add the **direction binding** dropdowns (windows axis / Spaces axis → normal | reversed), folding `reverseDirection` / `reverseVerticalDirection` into the binding (single source of truth, no duplicate keys).
- [x] 4.3 Hover-demo + rehearse reflect the chosen direction in the miniature.

## 5. Launcher page (one-per-page)

- [x] 5.1 Lead `LauncherPage` with the preview (4-finger ⇄ opens the launcher; scrub → dwell → lift) + switch-style `enableLauncher` toggle.
- [x] 5.2 Reuse the wizard's `LauncherView` demo-model pattern for the live miniature; no resolution-binding dropdowns (launcher activation/dwell is grammar-fixed).

## 6. Clipboard page (one-per-page)

- [x] 6.1 Lead `ClipboardPage` with the preview demoing the **full path** (4-finger open → traverse to the Clipboard band) via a scripted pose sequence + switch-style `keepClipboardHistory` toggle. Preview + toggle only (no own resolution binding).

## 7. Files page (one-per-page)

- [x] 7.1 Lead `FilesPage` with the preview demoing the **full path** (4-finger open → traverse to the Files band → lift = open) + switch-style `filesBandEnabled` toggle.
- [x] 7.2 Add the **drill resolution binding** dropdowns: `open / Open-With / discard` ← `{lift, +1-finger lift, four-finger ⇄}`, defaulting to today's mapping; mutually exclusive.

## 8. AI page (one-per-page — the hero)

- [x] 8.1 Lead `AIPage` with the preview demoing the **full path** (4-finger open → traverse to the AI band → the `AICommandCanvasView` miniature with its resolve) + switch-style `aiCommandsEnabled` toggle.
- [x] 8.2 Add the **canvas resolve binding** dropdowns: `commit / dismiss / ignore` ← `{swipe up, down, left, right}` (two-finger), defaulting to down=commit / horizontal=discard / up=ignore; mutually exclusive; exclude sub-threshold scroll + single-finger.
- [x] 8.3 Rehearse plays the real resolve animation (text commits / dismiss) in the miniature.

## 9. Binding model + consumption (cross-cutting)

- [x] 9.1 Add pure `GestureBindings` (MLX-free Core): per-surface action↔excursion maps, `assign(action:excursion:)` swap/conflict verdict, reserved-excursion exclusions; default == today's behavior. Unit-test conflicts and defaults.
- [x] 9.2 Persist bindings in `AppSettings` (new keys; default-preserving; included in reset semantics).
- [x] 9.3 Rewire `AppCoordinator.launcherCanvasResolve(dx:dy:)` to consult the canvas binding (keep the `canvasAtTop` commit guard binding-independent).
- [x] 9.4 Rewire the Files-drill resolution (`open`/`Open-With`/`discard`) and the switcher scrub-direction read to consult their bindings (discard still never kills a running app).

## 10. Verify

- [x] 10.1 `swift build` + `swift test` green; pure pose driver + `GestureBindings` (conflicts/defaults) + the rehearse-suppression gate covered. The full `ThreeFingerSwitcher` product builds + links (Core + GemmaRuntime/MLX).
- [x] 10.2 `openspec validate --strict` passes; spec deltas (`hub-gesture-previews`, `gesture-bindings` + the `configuration-hub`/`launcher-overlay`/`switcher-overlay`/`tunable-settings` modifies) match the implementation.
- [ ] 10.3 **User run-verify** in a stable-signed build: each gesture page shows a looping preview; hovering a binding demos it; real ≥2-finger touch rehearses without firing the feature; a remapped canvas commit (e.g. swipe-right) applies, and the old default still works after reset.

## 11. Realism refinement (real overlay miniatures + deterministic directed gestures)

> Make the previews show the ACTUAL switcher/launcher (live windows + bands, as in onboarding) and demonstrate gestures as deterministic directed strokes in the real finger-count grammar (open 3/4 → navigate 2 → dismiss 4).

- [x] 11.1 **Pose driver v2 (pure Core):** extend `GesturePose` with a **directed stroke** primitive (enter → ease from→to in the action direction with a slight human angle/arc → lift → loop) and a **multi-segment sequence** where each segment carries its OWN finger count (open 3/4 → navigate 2 → 4-finger dismiss). Expose metadata (finger count, segment index, segment progress, mid-lift) so the preview drives the miniature in sync. Keep the wizard's `.horizontal`/`.vertical`/`attractPose` working. Predefined gestures: `switcherDemo`, `launcherOpen`, `bandJourney(fraction)`, `canvasResolve(direction)`. Unit-test directedness, per-segment finger counts, bounds, looping.
- [x] 11.2 **Real demo content into the Hub:** wire `HubContext` with the wizard's providers — `realWindowRows() -> [[WindowInfo]]`, `seedThumbnails(SwitcherModel)`, `launcherBands(clipboardOn:aiOn:) -> [ContextBand]` — from the coordinator's existing closures (mirror `WizardContext` wiring in `makeHubContext`). No new permission.
- [x] 11.3 **Hub demo models:** a holder building a `SwitcherModel` (seeded with `realWindowRows` + thumbnails, sized for the mini) and a `LauncherModel` (seeded via `launcherBands`), as observable models the previews render and the pose loop drives.
- [x] 11.4 **Driven preview component:** enhance `HubGesturePreview` to render the **real** `SwitcherView(model:)` / `LauncherView(model:…)` and **drive the model from the pose sequence** — step `setColumn`/`stepHorizontal`/`stepVertical` in time with navigate strokes; **launch** the launcher in on the open stroke, dismiss on the 4-finger stroke. Keep the rehearse seam + hover-demo working.
- [x] 11.5 **Per-page wiring:** Switcher → real mini `SwitcherView` + `switcherDemo`; Launcher → real `LauncherView` + `launcherOpen`; Clipboard/Files/AI → real `LauncherView` showing their band via `bandJourney`, AI canvas resolve as a directed 2-finger swipe. Replace the light abstract miniatures from §4–§8.
- [x] 11.6 **Verify:** `swift build` + `swift test` green; new pose-v2 tests pass; `openspec validate --strict` passes.

## 12. Switcher preview — top-notch realism + a deterministic teaching story

> Make the Window-Switcher preview show the user's REAL windows (true proportions, multi-row Spaces) that grow/shrink with the size slider, and demonstrate the gesture as a precise teaching story (3-finger open → lift one → up/down Spaces → sideways windows) with the highlight + reel moving in sync.

- [x] 12.1 **Pose driver — connected strokes:** add a per-stroke `gapAfter` to `GesturePose.Stroke` (`0` = connected, no lift before the next), and rewrite `pose(phase:gesture:)` for variable per-stroke gaps so a finger-count change across a connected boundary reads as "lift one finger, keep going." Keep uniform-`liftGap` behavior byte-identical. Unit-test connected vs. lifted transitions.
- [x] 12.2 **Switcher demo holder (`HubSwitcherDemo`):** owns the real `SwitcherModel`; the teaching `DemoGesture` (open-3 → up-2 → down-2 → scrub-2, connected) + windows/spaces hover demos + the activation-threshold→open-length map; `onOpen`→reset, `onScrub`→centroid→(row, column) both-axis mapping; live `setMaxScale`. Plus a `SwitcherActionMap` legend view.
- [x] 12.3 **Real, scalable, multi-row content:** coordinator `realWindowRows` groups ALL Spaces (`SpaceGrouping`); `makeSwitcherModel(canvas:maxScale:)` applies the window-scale, falls back to two **icon-only** windows when ≤1 real window, and fabricates a sample second Space when <2 Spaces.
- [x] 12.4 **Page wiring:** `SwitcherPage` renders the real `SwitcherView(model:)` driven by the holder; live `.onChange` for window-scale (cards grow/shrink) and activation-threshold (open-swipe length); hover demos reflect the chosen axis; the action map sits under the preview.
- [x] 12.5 **Verify:** `swift build` + `swift test` green (new `HubSwitcherDemoTests` + connected-stroke pose tests); `openspec validate --strict` passes.
- [ ] 12.6 **User run-verify:** the Switcher preview shows real windows at true proportions across Spaces; the size slider grows/shrinks them live; the demo plays the open→lift-one→up/down→sideways story with the highlight + reel in sync; one-window and one-Space users still get a teachable scene.

## 13. Switcher preview — real-touch driving + grow-into-the-switcher

> When the user actually swipes, the highlight follows THEIR movement in steps (not the autoplay), and the mini grows into the full-size switcher — without ever firing the real switcher.

- [x] 13.1 **Driver opt-in rehearse seam:** `HubDemoDriver` gains an `onRehearse(centroid:fingerCount:)` closure; while rehearsing with it set, the tick drives the model from the user's REAL contacts (sampled per tick) instead of the autoplay script, and emits a lift edge `(nil, 0)`. Pages without it keep the legacy rehearse behavior.
- [x] 13.2 **Holder real-touch odometer:** `HubSwitcherDemo.rehearseStep(...)` mirrors the recognizer's grammar (activate on horizontal travel ≥ activation threshold → `rehearseActive`; then step windows on `stepDistance`, Spaces on `rowStepDistance`, honoring axis directions + wrap); `endRehearse()` recedes + resets; never fires.
- [x] 13.3 **Grow-into-the-switcher miniature:** `SwitcherDemoMiniature` renders the real `SwitcherView` and springs from a resting mini to a width-fitted full switcher on `rehearseActive`, in a reserved area so growing never reflows the page.
- [x] 13.4 **Verify:** `swift build` + `swift test` green (new rehearse-stepping + activation + recede tests); `openspec validate --strict` passes.
- [ ] 13.5 **User run-verify:** a real swipe over the focused preview steps the highlight with the hand (windows ↔, Spaces ↕) and grows the mini into the switcher; lifting recedes it; the real switcher never fires from the section.

## 14. Launcher + band previews — top-notch realism (grow-on-rehearse + real-story demo + live tunables)

> Mirror the Switcher work for the launcher: the user's ACTUAL launcher, idle playing the real usage story at preview scale, GROWING to near-real size under a real swipe (static, never fires), every launcher tunable reflected live. Then the same treatment on every band page (Clipboard / Files / AI). See design §13 (D8–D13); reuse `HubSwitcherDemo` as the template and the existing `gapAfter: 0` connected-stroke seam.

- [x] 14.1 **Launcher teaching gesture (reuse `gapAfter`):** added `HubLauncherDemo.teachingGesture(openLength:)` — a **four**-finger open stroke whose length = activation distance, then `gapAfter: 0` connected → drop to **two** fingers (4→2) → two-finger DOWN band-step / RIGHT item-step, then lift+loop. Plus `bandJourneyGesture(openLength:)` and `openLength(forActivation:)`, mirroring `HubSwitcherDemo`. Extended the `gapAfter` pose tests with `testFourToTwoConnectedHandOffNeverLifts`.
- [x] 14.2 **`LauncherTourEngine` (pure Core, settings-parameterized):** new `Gesture/LauncherTourEngine.swift` — the odometer-with-re-baseline + activation-threshold gate + per-axis step selection, reading the live tunables (`activationThreshold`/`itemStep`/`bandStep`) with `updateDistances`. Unit-tested in `LauncherTourEngineTests` (activation at threshold, item vs band step by focus, carry, re-baseline on count change, end-on-lift, live retarget). Dwell-arm/`manageDwell` lives in the holder (timer side effect).
- [x] 14.3 **Rework `HubLauncherDemo` to mirror `HubSwitcherDemo`:** owns the real `LauncherModel`; `seed(from:mode:dwell:activation:itemStep:bandStep:)`, `idleOpen()` (onOpen → home band), `idleNavigate(centroid)` (onScrub → engine item/band step), and a `playing` flag for the grow. Idle plays the teaching story at **preview scale**.
- [x] 14.4 **Grow-on-rehearse = morph into the ACTUAL launcher:** while `demo.playing`, a page-level `.overlay` (`GrownLauncherOverlay`) presents the **real `LauncherView` at native 1:1 size**, floating over the page on a dim backdrop, **navigable by the user's own fingers** (the small preview recedes). Shown at actual size whenever the Hub window fits it (scaled down only if not, never clipped). A lift recedes it and **disarms — never fires** (`recede()` / `launcherTourEnd` contract). Applied to all four pages (Launcher / Clipboard / Files / AI). (Superseded the initial in-place capped `scaleEffect` morph per the user's "ACTUAL launcher size" clarification.)
- [x] 14.5 **Drive the model from real fingers:** consumed the existing `HubDemoDriver.onRehearse(centroid, fingerCount)` seam (no coordinator/controller changes needed) → `rehearseFrame` / `rehearseEnd` feed the same `LauncherTourEngine` (≥4 grow/activate, 2 navigate, 0 end). The ≥2-finger ownership gate + `isKeyWindow` fail-safe are unchanged.
- [x] 14.6 **Live tunables + action map:** `LauncherPage` reads activation/item-step/band-step/dwell from **settings** (single source of truth) with live `.onChange` (rebuilds the teaching gesture on threshold; `updateDistances`/`setDwell` otherwise); added a `LauncherActionMap` legend under the preview.
- [x] 14.7 **All band pages:** Clipboard / Files / AI previews now use the reworked holder in `.bandJourney` mode (open → traverse to the band, growing on a real open) with the live tunables loaded.
- [x] 14.8 **Verify:** `swift build` (full app incl. GemmaRuntime/MLX) + `swift test` green — 1047 tests, 0 failures (4→2 connected pose + `LauncherTourEngine` covered); `openspec validate --strict` passes; spec deltas match.
- [ ] 14.9 **User run-verify:** in a stable-signed build, each launcher/band page idles with the real story at preview scale; a real four-finger swipe grows the user's actual launcher under the hand and navigates it without ever firing; every tuning slider visibly changes the preview.

## 14. Rehearse intent gating (arm on the opening trigger; two-finger scroll passes through)

> A real feature swipe always STARTS with the opening finger count (≥3: three switcher, four launcher/bands). Until that trigger, a two-finger move is an ordinary scroll and must pass through — so the Hub page scrolls normally and only an intentional trigger hands the gesture to a preview.

- [x] 14.1 **Arm on ≥3, then relax to two:** `HubRehearseGate` gains `armThreshold = 3` + `shouldArm(fingerCount:)`; `shouldDriveDots` / `ownsGestures` now require an `armed` flag. `HubRehearseController` latches `armed` on a ≥3-finger frame, clears it on a full lift (and on register/unregister/reset), so an un-armed two/one-finger move never drives or owns.
- [x] 14.2 **Swallow scroll only while armed:** the coordinator's scroll-consume predicate also consumes while `hubPreviewOwnsGestures` (an armed rehearsal), so the relaxed two-finger drive doesn't scroll the Hub page underneath — but an un-armed two-finger move keeps scrolling normally.
- [x] 14.3 **Verify:** `swift build` + `swift test` green (gate arm/relax + bare-two-finger-passthrough + arm-then-relax controller tests updated); `openspec validate --strict` passes.
- [ ] 14.4 **User run-verify:** two-finger scroll over a focused preview scrolls the Hub page; only a ≥3-finger trigger hands the gesture to the preview (then a relax to two keeps driving without the page scrolling).
