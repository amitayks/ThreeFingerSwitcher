# Tasks — remove-local-ai

## 1. Snapshot
- [x] 1.1 Branch `v1` + tag `v1.0.0` pushed; release CI builds the notarized DMG.
- [x] 1.2 Delete the merged side branches and their worktrees (all were fully merged into main).

## 2. Delete
- [x] 2.1 `Sources/GemmaRuntime/`, `Sources/ThreeFingerSwitcher/AI/`, `Files/`, `RegionPicker/`.
- [x] 2.2 Overlay: AI canvas, notch overlays, region picker, media player, BidiText, FilesBandView, FilesDwellArming, BubbleMorph.
- [x] 2.3 App/Settings/Hub/Gesture: ParkController, ModelManagementView, HubBackgroundAutonomy, HubFleetRosterView, HubFilesPage, FlickExcursionClassifier.
- [x] 2.4 Tests: 46 AI + 11 Files suites.
- [x] 2.5 Docs: the four ai-agent-v2 docs + notch-geometry-reference.
- [x] 2.6 openspec: 15 AI/Files capability specs, 16 active AI change folders, `explore/ai-command-band`.

## 3. Surgical edits
- [x] 3.1 `Package.swift` + `Package.resolved` + `main.swift` (MLX deps and injection out).
- [x] 3.2 `AppSettings` (45 keys + enums out), `GestureBindings` (switcher-only), `GesturePose` (canvasResolve out).
- [x] 3.3 `GestureRecognizer` (canvas-resolve / notch-flick / Files-drill sub-states out).
- [x] 3.4 Launcher stack: `LaunchItem` (kinds + speakLastResponse out, lossy decode in), `FavoritesStore` (v3 migration, no fold-in/seeded AI band), `LaunchService`, `LauncherModel`/`View`/`OverlayController`/`GridLayout`, `OverlayController` (SwitcherPanel simplification).
- [x] 3.5 Hub: `HubView` (destinations/seams), `HubFeaturePages` (AIPage out, demos trimmed), `BandsCanvas` (AI source/form/pickers out), `HubBindingPicker`, `HubOverviewPage`, `HubPreviewModels`.
- [x] 3.6 Onboarding: `WizardTourBands` (AI band out), `WizardContext`/`FirstTouchWizardModel`/`WizardActs`.
- [x] 3.7 `AppCoordinator` (~1,100 lines of AI/Files wiring out), `StatusItemController`, `AppDataReset`, `KeyboardSwitcherTap`.
- [x] 3.8 `build-app.sh`, `release.yml` (Xcode pin relaxed), `Info.plist` (5 usage strings out).
- [x] 3.9 README + CLAUDE.md rewritten for the refocused app.

## 4. Specs (in place)
- [x] 4.1 Trim `launcher-overlay`, `configuration-hub`, `tunable-settings`, `favorites-editor`, `first-run-onboarding`, `permissions-onboarding`, `gesture-recognition`, `launch-actions`.
- [x] 4.2 Rewrite the active `add-gesture-previews-and-bindings` gesture-bindings delta (switcher-only).

## 5. Verify
- [x] 5.1 `swift build` clean.
- [x] 5.2 `swift test` — 805 tests, 0 failures.
- [ ] 5.3 User: `INSTALL=1 ./scripts/build-app.sh` and confirm switcher / launcher / clipboard / Dock previews on the real signed build.
