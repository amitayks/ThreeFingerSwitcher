# Proposal — The great cleanup: remove the local AI stack and the Files band

## Why

The app drifted far from its intent. The features that earn daily use are the **window switcher**, the **four-finger launcher**, and **clipboard history**. The on-device AI platform (the command band, the conversational canvas, background agents, the notch timeline, voice/computer-use, the model fleet) and the Files band were built, shipped — and went unused. They carry enormous surface area: a second build path (MLX/Metal via `xcodebuild`), a multi-gigabyte model download, five extra TCC usage strings, ~150 source files, and roughly half the active spec estate. Cutting them refocuses the product and collapses the maintenance burden.

The pre-cleanup app is preserved in full: the **`v1` branch** and the **`v1.0.0` release tag** (a Developer-ID-signed, notarized DMG built by CI) snapshot everything before this change.

## What Changes

**Removed outright (code, tests, specs):**

- **On-device AI, all of it:** the `GemmaRuntime` target (MLX/Gemma 4, image/video runtimes), `Sources/ThreeFingerSwitcher/AI/` (executor, agent loop, tool routing, memory, skills, media, fleet, voice, computer-use, background autonomy/audit, parked sessions), the AI command canvas, the notch home zone + timeline, the region picker, the Hub AI page + fleet roster + autonomy views, `ModelManagementView`, the `.aiCommand` launch-item kind, the `speakLastResponse` system action, and the `mlx-swift`/`gemma-4-swift-mlx`/`flux-2-swift-mlx` package dependencies.
- **The Files band, all of it:** `Sources/ThreeFingerSwitcher/Files/`, `FilesBandView`/`FilesDwellArming`/`BubbleMorph`, `HubFilesPage`, the recognizer's Files-drill sub-state, the `.fileEntry` kind, and the `files*` settings.
- **Settings:** ~31 AI keys and ~14 Files keys (plus their enums) leave `AppSettings`; the canvas and Files-drill gesture bindings leave `GestureBindings` (older stored blobs still decode — unknown JSON keys are ignored).
- **Specs:** the 11 AI capability folders (`ai-*`, `on-device-ai-runtime`, `computer-use-tools`, `voice-conversation`, `screen-region-picker`, `selection-io`) and the 3 `files-*` folders are deleted; 16 active `ai-*`/notch change folders are deleted (the archive is untouched — it stays as design history).

**Modified (surgical):**

- `AppCoordinator` (~1,100 lines of AI/Files wiring out), `GestureRecognizer` (canvas-resolve, notch-flick, and Files-drill sub-states out), the launcher stack (`LauncherModel`/`View`/`OverlayController` lose canvas + Files threading), the Hub (AI/Files pages and seams out), onboarding (AI card + AI tour band out), `main.swift` (runtime injection out), `Package.swift`, `build-app.sh` (metallib copy rationale retired), `release.yml` (the Xcode 26.5 pin existed only for MLX), `Info.plist` (Calendar/Reminders/Contacts/Microphone/Speech usage strings out), README/CLAUDE.md.
- Mixed specs trimmed in place: `launcher-overlay`, `configuration-hub`, `tunable-settings`, `favorites-editor`, `first-run-onboarding`, `permissions-onboarding`, `gesture-recognition`, `launch-actions`, and the active `add-gesture-previews-and-bindings` delta (bindings are switcher-only now).

**Migration (the one real design point):**

- `Favorites` bumps to **schema v3** with a **lossy per-item band decode** (`ContextBand.FailableItem`): a stored record still carrying a retired kind (`.aiCommand`, `.action(.speakLastResponse)`) decodes with that item **dropped** instead of the whole record failing and being reseeded (which would wipe the user's bands). The v3 migration then removes the seeded "AI" band (recognized by its sentinel id) once it holds nothing else.

## Impact

- Affected code: −~200 files, −~40k lines; `swift build`/`swift test` now cover the whole app (no more MLX/`xcodebuild`-only target). 805 tests green (was 1,733; the deleted suites were AI/Files-only).
- No behavior change to the keepers: switcher, launcher, clipboard history, Dock previews, ⌘-Tab, window groups, minimize-all, keyboard language, device link, onboarding.
- Stale UserDefaults keys from removed settings are left in place (harmless); downloaded model weights are NOT auto-deleted — the user can remove `~/Library/Application Support/ThreeFingerSwitcher` content or the HF cache by hand if they want the disk back.
