# Tasks — media-player

> Sequencing: land after `positional-navigation` and `files-band` archive (the joystick grammar + the open seam must exist). All pure-Core tasks verify under `swift build` / `swift test`; engine conformers + the app verify via `xcodebuild` only. Core stays MLX-free **and** media-framework-free — the AVFoundation/libmpv code lives outside Core behind `MediaPlaybackEngine`.

## 1. Settings & opt-in (foundation)

- [x] 1.1 Add to `AppSettings`: `useBuiltInPlayer` (Bool, default false) + `Defaults`/`Keys`/`didSet`-persist entry, following the `enableDeviceLink`/`keepClipboardHistory` opt-in shape (no effectiveness gate, no gesture relocation).
- [x] 1.2 Add per-kind default-open flags `builtInPlayerHandlesVideo` / `…Audio` / `…Image` (Bool, defaults true) and a `builtInPlayerHandles(_ kind:)` accessor.
- [x] 1.3 Add player tunables: `playerDefaultEngine` (enum AVFoundation|libmpv, default AVFoundation), `playerSeekStep`, `playerVolumeStep`, `playerResumeThreshold`, `playerNearEndMargin` — persisted + live-applied.
- [x] 1.4 Confirm legacy decode: settings written before this change load with the opt-in OFF and tunables at defaults (extended `AppSettingsTests` — defaults/persistence, accessor, legacy decode, reset).

## 2. Pure Core — media-kind classification

- [x] 2.1 Add `Player/MediaKind.swift`: `enum MediaKind { case video, audio, image }` + `static func classify(_ entry: FileEntry) -> MediaKind?` via `UTType` conformance (`.movie`/`.audio`/`.image`), side-effect-free. *(Extension allowlist first for host-independent determinism, then UTType fallback.)*
- [x] 2.2 `MediaKindTests`: video/audio/image/non-media classification by UTI, including ambiguous/edge extensions (`.mkv`), directories, case-insensitivity.

## 3. Pure Core — the engine seam

- [x] 3.1 Add `Player/MediaPlaybackEngine.swift`: the `public @MainActor` protocol (`load(url)`, `play`/`pause`, `seek(by:)`/`seek(to:)`, `setRate`, `setVolume`, `audioTracks`/`subtitleTracks` + `selectTrack`, observable `status` + `onStatusChange`, `isAvailable`) — no media framework imported. *(public so the app-target conformers conform, like `LLMRuntime`.)*
- [x] 3.2 Add `Player/StubPlaybackEngine.swift`: a conformer that records calls and scripts load success / unsupported / loadFailed / decodeFailed / unavailability (mirrors `StubLLMRuntime`).
- [x] 3.3 Define `PlaybackEngineKind` (`avFoundation` / `libmpv`) used by settings, the fallback decision, and the action menu.

## 4. Pure Core — fallback decision & error taxonomy

- [x] 4.1 Add `Player/MediaPlayerError.swift`: `enum MediaPlayerError: LocalizedError` (`loadFailed`, `unsupportedByDefaultEngine`, `decodeFailed`, `engineUnavailable`) with clean per-case `errorDescription` + opt-in `copyableDetails`; parallel to `FileActionError`.
- [x] 4.2 Add `Player/MediaPlayerFallback.swift`: pure `offer(decodeFailed:failedEngine:availableEngines:)` → `.offerEngine` / `.engineUnavailable` / `.noFallback`. `MediaPlayerFallbackTests` cover all branches.

## 5. Pure Core — transport state machine

- [x] 5.1 Add `Player/PlayerTransportModel.swift`: `@MainActor ObservableObject` mapping positional intents → engine commands (seek ±step, volume ±step clamped 0…1, play/pause toggle, rate, track selection) + observable surface state (`.loading`/`.playing`/`.paused`/`.unsupported(...)`/`.failed(headline:details:)`); drives an injected `MediaPlaybackEngine`.
- [x] 5.2 Wire the AVFoundation→libmpv fallback into the model: a decode-failure transitions to `.unsupported`, `commitFallback()` / `switchEngine(to:)` swaps the injected engine and reloads at the current position; engine/OS errors arrive already mapped into `MediaPlayerError` at the boundary (never in Core).
- [x] 5.3 `PlayerTransportModelTests` (against `StubPlaybackEngine`): seek/volume step + clamp math, play/pause toggle, rate change, decode-failure → `.unsupported`, commit → libmpv reload, failure → observable `.failed` (never silent), dismiss is not a failure.

## 6. Pure Core — per-file resume store & action menu

- [x] 6.1 Add `Player/PlaybackStateStore.swift`: Codable per-file `{ resumePosition, duration, audioTrackID, subtitleTrackID, volume, rate, lastOpened, fileSize, modificationDate }`, keyed by abs path + size/mtime tiebreak, bounded LRU-by-`lastOpened` cap (the `ClipboardStore` retention pattern).
- [x] 6.2 Resume rule: pure `resumePosition(savedPosition:duration:threshold:nearEndMargin:)` returns saved position only when past threshold and outside near-end margin, else 0. `PlaybackStateStoreTests`: save/load round-trip, threshold/near-end rule, LRU eviction, moved-file (size/mtime mismatch) starts fresh.
- [x] 6.3 Add `Player/PlayerActionMenu.swift`: a pure model building the contextual rows (audio track, subtitle track + off, speed, loop, chapters, "open in libmpv") for a given media kind + engine capabilities; omit inapplicable rows (image omits all timeline rows). `PlayerActionMenuTests`.

## 7. Recognizer — the player modal sub-state (Core)

- [x] 7.1 In `GestureRecognizer`: add `playerActive: Bool { didSet { resetPlayer() } }` and route `trackPlayer(frame)` as a **first-statement bypass** in `feed()`, mirroring `filesDrillActive`/`launcherCanvasResolutionActive`. While active, emits no switcher/launcher intents.
- [x] 7.2 Implement `trackPlayer` on the anchored-positional model: 2-finger horizontal → `playerSeek(dir)` + held sign; 2-finger vertical → `playerVolume(dir)` + held sign (both axes auto-repeat); 2-finger tap (no travel) → `playerTogglePlayPause`; relative +1 → `playerActionMenu`; lift while `playerMenuOpen` → `playerSelectMenuItem`; ≥4 → `playerDismiss`. Re-anchors on every contact-count change.
- [x] 7.3 Added the new delegate methods (`playerSeek`/`playerVolume`/`playerTogglePlayPause`/`playerActionMenu`/`playerSelectMenuItem`/`playerDismiss`/`playerHeldZoneChanged`) with **default no-op extensions** so existing delegates still compile.
- [x] 7.4 `PlayerDrillRecognizerTests` (9 tests, modeled on `FilesDrillRecognizerTests`): bypass (3 fingers ≠ switcher), seek/volume + held sign on both axes, tap → toggle, scrub-then-lift ≠ toggle, relative +1 → action menu, ≥4 → dismiss, count-change → no phantom step, menu-open lift → select.

## 8. Open-routing branch (Core)

- [x] 8.1 In `FileOpenService.prepareOpen`: branch via injected `mediaPlaybackRoute`/`playMedia` closures (the controller builds them from `MediaKind.classify` + `useBuiltInPlayer` + `builtInPlayerHandles(kind)`) → hand to the player instead of `workspace.open`, preserving the defusable `PendingOpen` lifecycle. Open-With stays external (never routed).
- [x] 8.2 `FileOpenServiceTests` additions: media + opt-in-on routes to the player (workspace untouched); non-media / opt-in-off falls through to `workspace.open`; Open-With always external.

## 9. Player surface (Core — presentation; rendering injected)

- [ ] 9.1 Add `Overlay/PlayerOverlayController.swift`: owns its own `SwitcherPanel` (reused), full-screen, `.popUpMenu` + `[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`, **never** `keyInteractive`, never key/main. Open on the current Space; synchronous teardown on a Space-switching dismiss (files-band ghost landmine).
- [ ] 9.2 Add `Overlay/PlayerView.swift`: pure presentation over `PlayerTransportModel` state + a thin host for the engine's render layer (injected `NSView`/`CALayer` provider, so Core/the view stay engine-free); bubble-morph entrance/teardown; bounded non-blocking failure card (clean headline, capped length, copyable details disclosure, Retry / Dismiss / Open-in-libmpv) — never an `NSAlert`.
- [x] 9.3 Add a `PlayerController` (`@MainActor`) tying `play(entry, kind:)` → resume lookup → engine build/load → surface show → recognizer `playerActive = true`; transport-intent routing; action-menu open/highlight/select state; on dismiss persist state, hide, `playerActive = false`. (In `Overlay/PlayerOverlayController.swift`, with the `PlayerSurfacing` seam for testability.)
- [ ] 9.4 Image-viewer branch in `PlayerView`: still image (no seek/volume axes), 3-finger action menu + 4-finger dismiss consistent with video/audio.
- [x] 9.5 `PlayerControllerTests` (6 tests, against the stub engine + a fake surface): play shows surface + owns trackpad, dismiss persists+hides+releases, reopen resumes from saved position, action-menu open/highlight-move/select, image has no menu.

## 10. Engine conformers (app target / xcodebuild only)

- [ ] 10.1 Add `AVPlaybackEngine` (AVFoundation/AVKit) conforming to `MediaPlaybackEngine`: `AVPlayer` + `AVPlayerLayer`, hardware decode, container-carried audio/subtitle tracks, observable position via periodic time observer; map `AVError`/`NSError` → `MediaPlayerError` at this boundary; report decode failure for unsupported containers/codecs.
- [ ] 10.2 Add `LibmpvEngine` conforming to `MediaPlaybackEngine`: drive libmpv, expose its render layer, enumerate tracks (incl. external `.srt`), map libmpv error codes → `MediaPlayerError`; lazy construct + availability probe (missing/unloadable dylib → reports unavailable, never crashes).
- [ ] 10.3 Inject the engine factory at the seam in `main.swift` (where the real `LLMRuntime` is injected); `AppCoordinator` wires `PlayerController` + the opt-in gate + the default-engine setting.

## 11. Build & packaging

- [ ] 11.1 `scripts/build-app.sh`: bundle the libmpv dylib into `Contents/Resources/` and sign it as part of the bundle (the metallib precedent — miss it and the player is killed at first decode). Spike libmpv distribution (vendored prebuilt vs CI-built) so it notarizes cleanly with the release workflow.
- [ ] 11.2 Verify the AVFoundation + libmpv conformers and the app compile via `xcodebuild` (Core unaffected; MLX/`GemmaRuntime` split untouched).

## 12. Hub — Player page

- [ ] 12.1 Add a `HubPlayerPage` (model the `HubFilesPage`): opt-in toggle, per-kind default-open toggles, default-engine picker, seek/volume step controls, resume threshold/near-end controls — Liquid-Glass, live-applied, reflecting persisted values.
- [ ] 12.2 Add "Player" to the Hub sidebar (`HubView`) and the player opt-in to the Overview master toggles (`HubOverviewPage`).

## 13. Docs & spec sync

- [ ] 13.1 Update `CLAUDE.md` landmines: the player is a third sustained recognizer modal sub-state that owns the trackpad (3 fingers = action menu, not switcher), is non-activating (never key/main, unlike the AI canvas), and `build-app.sh` must bundle the libmpv dylib.
- [ ] 13.2 Update `README.md` (the feature brief + opt-in list + repo map for `Player/` and the engine conformers).
- [ ] 13.3 `openspec sync` (or the project's spec-update step) so `openspec/specs/` reflects the new `media-player` capability + the three deltas after implementation.

## 14. Verification

- [ ] 14.1 `swift build` + `swift test` green (all pure-Core logic: classification, engine seam/stub, transport state machine, fallback decision, resume store, action-menu model, recognizer sub-state) with existing tests still passing.
- [ ] 14.2 `xcodebuild` compile-check of the app + both engine conformers.
- [ ] 14.3 In-hand validation on a user-run stable-signed build: full-screen compositing in the non-key panel (AVFoundation first, then libmpv's layer), 2-finger scrub vs. incidental scroll, tap-vs-micro-scrub for play/pause, resume correctness, and the libmpv fallback offer.
