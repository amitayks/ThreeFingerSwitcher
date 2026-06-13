## Why

The Files band lets you reach any local file by trackpad and **open** it — but opening hands the file to another app, teleporting your attention out of the platform and onto whatever launches. A video, a track, or an image you reached by muscle memory should *play in place*, driven by the same trackpad grammar you used to find it: scrub with two fingers, raise a contextual action menu with three, dismiss with four. macOS has no such player, and the app's positional-navigation language is now general enough to drive one. The same machinery that proved an interactive, non-activating overlay (the AI canvas) and a modal trackpad sub-state (the Files drill) is exactly what a player needs — so this is composition, not new invention.

## What Changes

- A new **built-in media player** (opt-in, default off) that opens **video, audio, and images** from the Files band: land on a playable file and **lift to open** drops you into a full-screen, trackpad-driven player on the **current Space** — no app launch, no teleport. When the opt-in is off, opening a media file behaves exactly as today (system default app).
- **Dual playback engine behind one seam.** A `MediaPlaybackEngine` protocol (the player's `LLMRuntime`/`FileWorkspace`-style seam) with **two conformers shipping in v1**: **AVFoundation** is the default (native, hardware-accelerated); **libmpv** is the alternative — **auto-offered when AVFoundation cannot decode** a file, and selectable on demand from the action menu ("open in libmpv"). All player *logic* stays in MLX-free Core against a `StubPlaybackEngine`; only the rendering conformers need the app/`xcodebuild` path.
- **Trackpad-only transport grammar**, adopting the converging positional-navigation joystick: **2 fingers** horizontal = seek (eased hold-to-fast-forward), vertical = volume; a **2-finger tap** toggles play/pause; **3 fingers** (relative +1) raise a scrubbable **action menu** (subtitle track, audio track, speed, loop, chapters, "open in libmpv"); **4 fingers** dismiss the player. While the player is open it **owns the trackpad** — 3 fingers is its action menu, not the global window switcher.
- **Per-file resume.** A `PlaybackStateStore` remembers position, audio/subtitle track, volume, and rate per file (keyed by path/content hash) and **resumes on reopen** past a threshold.
- A **Hub → Player page**: the opt-in, per-media-kind default-open toggles, default engine, seek/volume increments, and resume behavior.
- **BREAKING (build):** `build-app.sh` must bundle the **libmpv dylib** into `Contents/Resources/` (a metallib-class packaging requirement — miss it and the player is killed at first decode).

## Capabilities

### New Capabilities
- `media-player`: the in-app player domain — the opt-in and Files-band open-routing branch, media-kind classification, the `MediaPlaybackEngine` seam plus the AVFoundation (default) and libmpv (fallback/on-demand) conformers, the pure transport state machine, per-file resume/state persistence, the action menu, the image viewer, the AVFoundation→libmpv fallback decision, and an error taxonomy (parallel to `FileActionError`/`RuntimeError`) whose failures are observable, bounded, and non-blocking — never raw error text.

### Modified Capabilities
- `gesture-recognition`: add a sustained **player modal sub-state** (`playerActive` → `trackPlayer`) routed as a first-statement `feed()` bypass — mirroring `filesDrillActive`/`launcherCanvasResolutionActive` — emitting transport intents (seek / volume / toggle / action-menu / select / dismiss), reusing the relative **+1-finger** action-menu intent and mandatory contact-count re-baselining.
- `configuration-hub`: add a **Player** page to the sidebar (opt-in, per-kind default-open, default engine, seek/volume increments, resume behavior).
- `tunable-settings`: add the player opt-in + tunables (seek step, volume step, resume threshold, default engine, per-kind default-open) — persisted, live-applied; the auto-repeat curve is reused from positional-navigation.

> The **Files-band open-routing branch** and the **non-activating player surface** are owned by the new `media-player` capability rather than `files-band`/`launcher-overlay` deltas: the player is a *separate* overlay from the launcher (which dismisses on lift-to-open), and `files-band` is itself still an unarchived in-progress change. This mirrors how `positional-navigation` touches the files drill in code while declaring deltas only against already-landed specs. The `FileOpenService` branch is a code edit (see Impact), not a `files-band` spec change.

## Impact

- **New files (Core, MLX-free):** `Player/MediaKind.swift` (UTI classification), `Player/MediaPlaybackEngine.swift` (the seam + `StubPlaybackEngine`), `Player/PlayerTransportModel.swift` (pure transport state machine), `Player/PlaybackStateStore.swift` (Codable per-file state), `Player/PlayerActionMenu.swift` (action-menu model), `Player/MediaPlayerError.swift` (the taxonomy), `Overlay/PlayerOverlayController.swift` + `Overlay/PlayerView.swift` (the surface — view is presentation; rendering is injected).
- **New files (engine conformers, app/`xcodebuild` only):** an `AVPlaybackEngine` and a `LibmpvEngine` conforming to `MediaPlaybackEngine`, injected at the seam in `main.swift` (the same place the real `LLMRuntime` is injected). libmpv added as a bundled dylib.
- **Surgical edits:** `FileOpenService` (the open-routing branch), `GestureRecognizer` (the `playerActive` sub-state + transport intents + delegate methods with default no-ops), `AppCoordinator` (player controller wiring + flag gating + engine injection), `AppSettings` (the opt-in + player tunables), the Hub (`HubView` sidebar + a Player page), and `scripts/build-app.sh` (bundle the libmpv dylib).
- **Dependencies:** AVFoundation/AVKit (system, zero-cost) and **libmpv** (bundled native dylib). No new permission, no native-gesture relocation, no re-login. The MLX/`GemmaRuntime` split is untouched.
- **Sequencing:** depends on `positional-navigation` (the joystick grammar) and `files-band` (the open seam) landing first — both effectively complete.
- **Verification:** all Core logic (transport state machine, scrub/volume/resume math, media-kind classification, state store, libmpv-fallback decision, action-menu model) via `swift build`/`swift test` against `StubPlaybackEngine`, existing tests staying green; the rendering conformers compile-verified via `xcodebuild` only.
- **Non-goals (v1):** file operations, remote/network/streaming sources, casting/AirPlay, and any playlist/queue beyond per-file resume (a "Continue watching" band is a deliberate follow-up).
