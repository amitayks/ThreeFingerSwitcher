> Decomposed for a workflow fan-out: §1–§2 are the shared substrate (do first), §4–§8 are **one per page** and independent once the substrate lands, §9 is the cross-cutting binding consumption, §10 verifies.

## 1. Pose driver (pure Core)

- [ ] 1.1 Lift `FirstTouchWizardModel.attractPose` into MLX-free Core as `GesturePose.pose(phase:fingers:axis:)`, parameterized by **finger count** (2/3/4 → number of fingertip offsets) and **axis** (`.horizontal` ping-pong, `.vertical`, `.scripted(excursion)` one-shot for hover-demo). Keep it pure/`nonisolated`.
- [ ] 1.2 Repoint the wizard's `attractPose` call at the shared function (no behavior change to onboarding); keep/port the existing bounds/shape unit tests.
- [ ] 1.3 Unit tests: 2/3/4-finger poses stay in `[0.05, 0.95]`; horizontal vs vertical centroid travel; a scripted excursion runs start→end→loop.

## 2. Preview substrate (Hub + live touch)

- [ ] 2.1 Add `HubGesturePreview` (`Hub/`): a live overlay miniature slot over a generalized `FingerDotsPad`, with the three states — **attract** (loops the bound gesture), **hover-demo** (loops a candidate excursion), **rehearse** (real touch). Reuse `WizardMotion` (`PulseHalo`/`BreathingGlowBackdrop`/`ShimmerSweep`).
- [ ] 2.2 Generalize/relocate `FingerDotsPad` so it is shared by the wizard and the Hub (count-agnostic already; expose finger count + live flag).
- [ ] 2.3 Hub-local live-touch subscription: subscribe to the `TouchEngine` feed only while a preview is on screen/focused; gate to **≥2 fingers**; map contacts → dots + drive the miniature.
- [ ] 2.4 **Rehearse-does-not-fire isolation:** while a preview is rehearsed, suppress real gesture handling (reuse the `wizardOwnsGestures` precedent); resume on focus-loss / lift. Verify a Hub rehearse never opens the launcher or fires a command.

## 3. Switch-style master toggle + a previewed-section scaffold

- [ ] 3.1 Add a `HubFeatureHeader` (or extend `HubPage`) that renders the `HubGesturePreview` then the Overview-style master toggle row (icon + title + subtitle + `.switch`, mirroring `OverviewPage.featureRow`) directly beneath it.
- [ ] 3.2 Leave all secondary controls (`LabeledSlider`/`Picker`/buttons) untouched — only the leading master enable is restyled.

## 4. Switcher page (one-per-page)

- [ ] 4.1 Lead `SwitcherPage` with the preview (3-finger ⇄ for windows; 3-finger ⇅ for Spaces) + switch-style `enabled` toggle.
- [ ] 4.2 Add the **direction binding** dropdowns (windows axis / Spaces axis → normal | reversed), folding `reverseDirection` / `reverseVerticalDirection` into the binding (single source of truth, no duplicate keys).
- [ ] 4.3 Hover-demo + rehearse reflect the chosen direction in the miniature.

## 5. Launcher page (one-per-page)

- [ ] 5.1 Lead `LauncherPage` with the preview (4-finger ⇄ opens the launcher; scrub → dwell → lift) + switch-style `enableLauncher` toggle.
- [ ] 5.2 Reuse the wizard's `LauncherView` demo-model pattern for the live miniature; no resolution-binding dropdowns (launcher activation/dwell is grammar-fixed).

## 6. Clipboard page (one-per-page)

- [ ] 6.1 Lead `ClipboardPage` with the preview (4-finger ⇄ → the last band) + switch-style `keepClipboardHistory` toggle. Preview + toggle only (no own resolution binding).

## 7. Files page (one-per-page)

- [ ] 7.1 Lead `FilesPage` with the preview (4-finger ⇄ → Files band; lift = open) + switch-style `filesBandEnabled` toggle.
- [ ] 7.2 Add the **drill resolution binding** dropdowns: `open / Open-With / discard` ← `{lift, +1-finger lift, four-finger ⇄}`, defaulting to today's mapping; mutually exclusive.

## 8. AI page (one-per-page — the hero)

- [ ] 8.1 Lead `AIPage` with the preview using an `AICommandCanvasView` miniature + switch-style `aiCommandsEnabled` toggle.
- [ ] 8.2 Add the **canvas resolve binding** dropdowns: `commit / dismiss / ignore` ← `{swipe up, down, left, right}` (two-finger), defaulting to down=commit / horizontal=discard / up=ignore; mutually exclusive; exclude sub-threshold scroll + single-finger.
- [ ] 8.3 Rehearse plays the real resolve animation (text commits / dismiss) in the miniature.

## 9. Binding model + consumption (cross-cutting)

- [ ] 9.1 Add pure `GestureBindings` (MLX-free Core): per-surface action↔excursion maps, `assign(action:excursion:)` swap/conflict verdict, reserved-excursion exclusions; default == today's behavior. Unit-test conflicts and defaults.
- [ ] 9.2 Persist bindings in `AppSettings` (new keys; default-preserving; included in reset semantics).
- [ ] 9.3 Rewire `AppCoordinator.launcherCanvasResolve(dx:dy:)` to consult the canvas binding (keep the `canvasAtTop` commit guard binding-independent).
- [ ] 9.4 Rewire the Files-drill resolution (`open`/`Open-With`/`discard`) and the switcher scrub-direction read to consult their bindings (discard still never kills a running app).

## 10. Verify

- [ ] 10.1 `swift build` + `swift test` green; pure pose driver + `GestureBindings` (conflicts/defaults) + the rehearse-suppression gate covered. The full `ThreeFingerSwitcher` product builds + links (Core + GemmaRuntime/MLX).
- [ ] 10.2 `openspec validate --strict` passes; spec deltas (`hub-gesture-previews`, `gesture-bindings` + the `configuration-hub`/`launcher-overlay`/`switcher-overlay`/`tunable-settings` modifies) match the implementation.
- [ ] 10.3 **User run-verify** in a stable-signed build: each gesture page shows a looping preview; hovering a binding demos it; real ≥2-finger touch rehearses without firing the feature; a remapped canvas commit (e.g. swipe-right) applies, and the old default still works after reset.
