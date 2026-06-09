# Implementation Tasks — AI Command Band

> Build order is dependency-first. Phases 1–9 compile and test under the project's `swift build` / `swift test` rule (CLAUDE.md) using the **stub runtime**. The real MLX/Gemma runtime (Phase 10) lives in an isolated target built via `xcodebuild`. Do NOT assemble/install the `.app` from the agent shell — verify logic with `swift build` / `swift test` only; the user does the signed in-app build.

## 1. Dependencies, module layout, and build isolation

- [x] 1.1 Add a new `AI/` source group under `Sources/ThreeFingerSwitcher/` for all model/command/selection/task code. — created `Sources/ThreeFingerSwitcher/AI/` in the `ThreeFingerSwitcherCore` target (auto-built by `swift build`).
- [x] 1.2 Decide and document module boundaries: core feature code (band, executor, selection, tasks, stub runtime) must compile under `swift build`; the MLX-backed runtime must be isolated so its Metal/MLX dependencies never enter the `swift build` graph. — decided + documented in design.md; core ships behind the `LLMRuntime` stub, MLX deferred to a separate Xcode-only target.
- [x] 1.3 `Package.swift` declares the isolated `GemmaRuntime` target (the only one linking MLX); it's depended on by the app target only (not by Core/tests), so `swift test` stays MLX-free and the app builds via `xcodebuild`.
- [x] 1.4 Added the `gemma-4-swift-mlx` dependency (transitively pulls mlx-swift / swift-transformers / mlx-swift-lm). **Resolved + verified:** gemma-4-swift-mlx(main), **mlx-swift 0.31.4** (recent → avoids the macOS-26 `bfloat16` break), mlx-swift-lm(main), swift-transformers 1.3.3, swift-jinja 2.3.6, swift-syntax 603.0.2. *(No `mlx-swift-structured` — `structured()` uses validate/repair/decline, no constrained-decoding dep.)*
- [x] 1.5 Updated `README.md` (B1 repo map: `AI/` + `Sources/GemmaRuntime/`; B2: the MLX split + Metal toolchain `xcodebuild -downloadComponent MetalToolchain` + the metallib-bundle landmine) and `CLAUDE.md` ("On-device AI (MLX) — build & landmines" section + the agent-uses-`xcodebuild`-to-compile-verify note). `build-app.sh` already migrated to `xcodebuild`.
- [x] 1.6 Verify `swift build` and `swift test` still pass with the new `AI/` group. — green: `swift build` clean, `swift test` 341 passed / 0 failures.

## 2. Model runtime abstraction (`LLMRuntime`) — the swappable seam

- [x] 2.1 Define `AI/LLMRuntime.swift`: the `LLMRuntime` protocol with `capabilities: Set<Modality>` (`.text`, `.vision`; reserved `.audio`), async streaming `generate(_:) -> AsyncThrowingStream<Token, Error>`, and `structured<T: Decodable & Sendable>(_:schema:as:) async throws -> StructuredOutcome<T>` (returns `.value`/`.declined` per design D2).
- [x] 2.2 Define request/response value types: `LLMRequest` (prompt, optional image, params), `Token` (text + isFinal), `Modality`, and `RuntimeError` (unavailable, modelMissing, integrityFailed, cancelled, couldNotProduceValid, decodeFailed, unsupportedModality).
- [x] 2.3 Define `StructuredSchema` representation (JSON Schema wrapper) used by both `structured(...)` and the task layer.
- [x] 2.4 Confirm no feature code imports a concrete model type — only `LLMRuntime` (concretes stay behind the seam; real MLX conformer in the deferred target).

## 3. Stub runtime (keeps core building/testing without MLX)

- [x] 3.1 Implement `AI/StubLLMRuntime.swift` conforming to `LLMRuntime`: deterministic, scriptable responses; scripted structured outcomes (`.valid` / `.invalidThenRepaired` / `.alwaysInvalid` / `.decline`) exercising validate/repair/decline.
- [x] 3.2 Stub supports injectable scripted outputs and an artificial inter-token delay for exercising streaming/cancellation in tests.
- [x] 3.3 Honor cancellation (stop emitting on Task cancel) so the discard path is testable — covered for both `generate` and `structured`.
- [x] 3.4 Unit tests: streaming order, cancellation (streaming + structured), structured decode, repair/retry, decline, capability reporting, vision accept/reject, schema validation in isolation.

## 4. Model registry and capability-based selection

- [x] 4.1 Define `AI/ModelRegistry.swift`: `ModelDescriptor` (id, displayName, sizeBytes, integritySHA, downloadURL, `capabilities`, quantization) + registry (31B default text+vision; 26B-A4B speed alt; 12B reserved with `.audio`). *(SHAs/URLs are placeholders pending Phase 10 real weights.)*
- [x] 4.2 Capability-based selection: `selectModel(requiring:)` returns the best matching descriptor (vision → vision-capable), else throws `.unavailable`.
- [x] 4.3 Default model id configurable (`defaultModelID` — 31B↔26B-A4B is a one-line switch).
- [x] 4.4 Unit tests: selection picks vision-capable; fails clearly on no-match; default preference + fallback ordering.

## 5. Model lifecycle (`ModelManager`)

- [x] 5.1 Implement `AI/ModelManager.swift` (`@MainActor ObservableObject`): resolves the active `LLMRuntime` (via a `runtimeFactory` swap point), owns download/verify/load/evict, exposes `@Published` `ModelLifecycleState` (`notDownloaded`, `downloading(progress)`, `verifying`, `ready`, `loading`, `loaded`, `failed`).
- [x] 5.2 Download via injectable `ModelDownloading` protocol (tests use a fake, no network), opt-in-gated; never starts while opted out.
- [x] 5.3 Integrity verification (CryptoKit SHA256) before load; corrupt download → `.failed`, never loaded.
- [x] 5.4 Lazy load on first use; keep resident between calls (no re-load/re-download); `evict()` on demand and on opt-out. *(Memory-pressure auto-evict hook to wire when AppKit lifecycle is integrated in a later slice.)*
- [x] 5.5 Expose loading state observably (`@Published state`) — covered by an intermediate-state observation test.
- [x] 5.6 Strong-hardware-only guard: reports `.unavailable` when a model can't be served (no silent degrade).
- [x] 5.7 Unit tests (stub + fake downloader): no download when opted out; corrupt-hash rejection; residency across two calls; eviction; intermediate loading-state sequence.

## 6. Selection I/O (`SelectionService`) — the new primitive

- [x] 6.1 Implement `AI/SelectionService.swift` (conforms to `SelectionProviding`, injected `frontAppProvider`). Reuses the existing `axString` AX helper; **zero edits to `AXPrivate.swift`/`LaunchService`** (CGEvent synth is a private helper in the new file).
- [x] 6.2 `readSelectedText()` via AX (`kAXFocusedUIElementAttribute` → `kAXSelectedTextAttribute`) on the captured front app; no clipboard mutation on the happy path; returns nil (not "") when no selection.
- [x] 6.3 ⌘C-with-restore fallback inside `readSelectedText()`: snapshot pasteboard (per-item typed bytes), synthesize ⌘C to the captured pid, poll `changeCount` (bounded ~0.5s), read, **always restore** — sensitive/non-text clipboard survives byte-for-byte.
- [x] 6.4 `replaceSelection(_:)`: set `kAXSelectedTextAttribute` when `AXUIElementIsAttributeSettable`, else paste-with-restore; `pasteAtCursor(_:)` pastes at the caret with restore.
- [x] 6.5 `captureScreenRegion() -> Data?` (PNG) via ScreenCaptureKit, gated on Screen Recording (returns nil when not granted). *(Interactive region PICKER deferred to slice 5/phase 12 — captures main display for now.)*
- [x] 6.6 "No input" handling: `normalized()` treats empty/whitespace as no-selection; executor surfaces `.noInput` and never runs the model on empty.
- [x] 6.7 Unit tests (17): pasteboard save/restore round-trip (incl. non-text/password survival) behind an injectable `PasteboardAccess`, no-input decisions, Screen-Recording gate, PNG encoding — AX/⌘C/⌘V/SCK NOT faked. Manual-test checklist produced for the signed build (see slice report).

## 7. AI command model + persistence

- [x] 7.1 Define `AI/AICommand.swift`: `AICommand` (id, name, `ItemIcon`, `ItemColor?`, `InputSource`, `promptTemplate`, `OutputTarget`, `ModelSelector`, `confirmBeforeRun`) + `InputSource`/`OutputTarget`/`TaskKind`/`Destination`/`ModelSelector` enums — all `Codable, Equatable, Sendable`; reuses `ItemIcon`/`ItemColor` from LaunchItem; computed `requiredCapabilities`.
- [x] 7.2 `confirmBeforeRun` derives to true for side-effecting outputs ONLY at creation (`defaultConfirmBeforeRun(for:)`); an explicit/stored value is taken verbatim and honored at run time (survives Codable round-trip; never re-imposed).
- [x] 7.3 Implement `AI/AICommandStore.swift`: dedicated `@MainActor ObservableObject` store (own `aiCommands` UserDefaults key, separate from Favorites; versioned blob + `migrate()`; `mutate()` funnel, immediate save). **Seed-id stability fixed + regression-tested.**
- [x] 7.4 Default command set seeded on first use (Fix Grammar, Make Concise, Translate, Explain, Summarize, Add to Calendar) with sensible templates; missing record decodes empty when seeding suppressed.
- [x] 7.5 Unit tests: round-trip persistence; ordering; missing-key→empty; seeded-id stability; confirm-defaults-on-but-honored invariant.

## 8. Prompt templating

- [x] 8.1 Implement `AI/PromptTemplate.swift`: single-pass resolve of `{input}`/`{date}`/`{app}`/`{url}` from a `FireContext`.
- [x] 8.2 Unknown tokens left untouched; missing `{url}`/`{app}`/`{input}` → empty string; substituted values not re-scanned; never fails.
- [x] 8.3 Unit tests: substitution, missing-token degradation, unknown-token passthrough, value-not-rescanned, lone-brace.

## 9. Command executor (in-place orchestration)

- [x] 9.1 Implement `AI/AICommandExecutor.swift` (`@MainActor ObservableObject`): fire → acquire input (via the `SelectionProviding` seam, selection→clipboard fallback, **whitespace-only treated as empty**) → resolve template → select model (`ModelManager`, capability-based) → stream → expose result. Depends only on protocols.
- [x] 9.2 Streaming result driven as `@Published State` (idle/loadingModel/noInput/streaming/ready/declined/failed/committed) for the canvas; cancellable (horizontal discard swipe).
- [x] 9.3 Route committed in-place output (`replaceSelection`/`pasteAtCursor`/`previewOnly`) via the `SelectionProviding` seam; task/sendTo routed via the `TaskDispatching` seam with stored confirm honored.
- [x] 9.4 Surface the no-input and model-loading states.
- [x] 9.5 Unit tests (stub + fakes): full in-place pipeline; cancellation (deterministic, via observed-cancellation); previewOnly writes nothing; replaceSelection routes to writer; whitespace→no-input; task path routes with confirm honored.

## 10. Real Gemma 4 runtime (`GemmaRuntime` target, xcodebuild only)

- [x] 10.1 Implemented `GemmaMLXRuntime: LLMRuntime` over `Gemma4Pipeline` — `generate` maps `chatStream(prompt:temperature:maxTokens:) -> AsyncThrowingStream<String,Error>` to streamed `Token`s; injected at the app entry via `AIRuntimeInjection.modelManagerFactory` (Core stays model-agnostic).
- [~] 10.2 Vision **deferred** (v1): `chatStream` is text-only, so the runtime advertises `[.text]` and **honestly refuses** an image request with `.unsupportedModality(.vision)` (no silent degrade). Widening to vision = a future image-aware pipeline call.
- [x] 10.3 `structured(_:schema:)` = schema-targeted prompt → bounded validate/repair/retry → decode, with a first-class `.declined` ("not applicable") path. No constrained-decoding dependency (matches the relaxed stance).
- [x] 10.4 Download/load reconciled via a `ModelManager` **provisioner** seam: the Gemma path delegates download+load to `Gemma4Pipeline.load(downloadIfNeeded:progress:)` (HF-Hub, integrity-verified), mapping 0…1 progress to `.downloading` → `.loaded`; the dev-stub byte/SHA path is untouched. Model = `mlx-community/gemma-4-31b-it-4bit` (~17 GB, ungated).
- [~] 10.5 Cancellation stops token **delivery** + surfaces `.cancelled` promptly; underlying MLX generation isn't torn down (the vendored `chatStream` wrapper doesn't forward termination — documented; future fix drives `ChatSession` directly).
- [x] 10.6 Built `GemmaRuntime` + app via `xcodebuild` (Metal toolchain installed): **`** BUILD SUCCEEDED **`** (mlx-swift + Metal + GemmaRuntime + 74.6 MB app). `swift test` stays green at 433. `build-app.sh` migrated to `xcodebuild`, stable signing preserved.

## 11. Launcher band integration

- [x] 11.1 Added synthetic `case aiCommand(AICommand)` to `LaunchItemKind` (Codable/Equatable; `isConsequential==false`; non-persisted in Favorites like `.clipboardEntry`). Round-trip tested.
- [x] 11.2 Implemented `AI/AICommandBandBuilder.swift` (mirrors `ClipboardBandBuilder`): builds a synthetic `ContextBand` (sentinel id, `isAICommandBand`/`shouldPresent`) from `AICommandStore`; present only when opt-in on AND commands exist. Tested (5 cases).
- [x] 11.3 `AppCoordinator` injects the AI band at launcher open gated on `shouldPresent`, built fresh each open (reusing `capturedFrontApp`), never written to Favorites; gates re-show while `canvasActive`.
- [x] 11.4 `LauncherView` renders `.aiCommand` items (icon+label+tint via existing paths) + a `sparkles` kind-marker; `FavoritesEditorView` switches handle the synthetic kind.
- [x] 11.5 `LaunchService.fire()` has an `.aiCommand` branch routing to an injectable `onAICommand` (→ `AICommandExecutor.fire`), which does NOT dismiss.

## 12. Overlay: streaming preview canvas + swipe-to-resolve

- [x] 12.1 Added `Overlay/AICommandCanvasView.swift` (mirrors `ClipboardBandView` + async update) bound to `AICommandExecutor.State`; renders loadingModel/noInput/streaming/ready/reviewingAction/declined/failed.
- [x] 12.2 `LauncherModel` (`enterCanvas`/`exitCanvas`/`canvasActive`) + `LauncherOverlayController.end()` case 2: firing an armed AI command opens the canvas WITHOUT ordering out; overlay stays visible, never key. Non-AI path unchanged (regression-guarded).
- [x] 12.3 Swipe-to-resolve: a fresh four-finger **down** swipe commits and a **horizontal** swipe discards (an **up** swipe is ignored), via a one-shot **canvas-resolution mode** in `GestureRecognizer` (`launcherCanvasResolutionActive`, toggled by `LauncherOverlayController.onCanvasStateChanged`) that emits `launcherCanvasResolve(dx:dy:)`; `AppCoordinator` routes down→`resolveCanvasCommit()`→`executor.commit()` (per output target) and horizontal→`discardCanvas()`→`cancel()`. A down swipe before the result is committable is **ignored** (`State.isCommittable` gate); a stray re-lift while the canvas is open is a no-op (`end()` case 1). Covered by `GestureRecognizerLauncherTests` (resolution mode) + `LauncherCanvasModeTests`.
- [x] 12.4 Armed-confirmation state: the canvas renders the parsed action's review fields when `confirmBeforeRun` on; a down-swipe commit fires the side effect, a horizontal swipe cancels (executor `.reviewingAction`).
- [x] 12.5 Captured app stays frontmost (non-activating panel; canvas never becomes key) — asserted by the canvas-mode tests.
- [x] 12.6 Manual-test checklist produced (stream→down-swipe-commit, stream→horizontal-discard, task→confirm→fire, task→discard, down-swipe-while-streaming→ignored, up-swipe→ignored) — see `MANUAL-TEST.md`; run in your signed build.

## 13. Background tasks (agentic)

- [x] 13.1 Define `AI/Tasks/TaskKind.swift` schemas (one `StructuredSchema` per task) and a `ParsedAction` type per kind; include an explicit decline / "not applicable" + confidence affordance so the model can refuse rather than fabricate; wire each to `structured(...)`. — `AI/Tasks/ParsedActions.swift`: `ParsedCalendarEvent`/`ParsedSaveToProject`/`ParsedOpenTool`/`ParsedSendTo` (each `Decodable & Sendable`) + a `StructuredSchema` carrying an explicit `applicable` decline affordance; wired through `runtime.structured(...)` in `TaskDispatcher.parse(...)`.
- [x] 13.2 Implement `AI/Tasks/TaskDispatcher.swift`: validate the parsed action (repair/retry on mismatch; treat a decline as no-action), build the action-review model, and execute on commit — showing the action-review (armed-confirmation) state when the command's `confirmBeforeRun` is on (default for side effects) and skipping it when the user has turned it off. — `prepare(kind:resolvedPrompt:source:) -> TaskReview` (`.action`/`.declined`/`.unavailable`) + `execute(_:)`; `TaskReview` in `AI/Tasks/TaskReview.swift`; executor lands in `.reviewingAction` when confirm on, direct-executes when off (honored).
- [x] 13.3 `CalendarTask` (EventKit): map `{title,start,end,attendees,notes}` → `EKEvent`; create only after confirm and permission grant. — `EventKitCalendarSink` (behind the `CalendarSink` seam) in `AI/Tasks/TaskSinks.swift`; lazy permission via `PermissionsService.requestCalendarAccess()`; tests use a fake sink (real EventKit prompt is manual-only).
- [x] 13.4 `SaveToProjectTask`: append content + source app/URL + timestamp to a per-project note on disk (reuse the clipboard store on-disk pattern); project is part of task config. — `DiskProjectStore` (behind `ProjectStore`) appends to a per-project `.md` under Application Support, mirroring `ClipboardStore.defaultDirectory()`.
- [x] 13.5 `OpenToolTask`: generate payload (file/prompt) and open the target tool via `LaunchService open` or a Shortcut. — `WorkspaceToolOpener` (behind `ToolOpener`) writes a payload temp file and opens the tool (app via `NSWorkspace`, named Shortcut via `shortcuts run`).
- [x] 13.6 `SendToTask`: destination adapter (Shortcut / URL scheme / shell-out) fed the optionally-refined content. — `AdapterDestinationSender` (behind `DestinationSender`): Shortcut (`shortcuts run`), URL scheme (`{content}` substitution), shell-out (stdin).
- [x] 13.7 Unit tests (stub runtime): each task produces a schema-valid action or a clean decline; non-conforming output is repaired/retried, never dispatched raw; the dispatcher shows the action-review when `confirmBeforeRun` is on and skips it when off (honoring the stored value); discard yields no side effect. — `TaskDispatcherTests` (18) + new `AICommandExecutorTests` cases (review-on/off, discard, decline, unavailable). 410 total, green.

## 14. Permissions (Calendar/EventKit)

- [x] 14.1 Extend `PermissionsService.swift`: detect EventKit authorization; request **lazily** at first calendar-task use (never at launch / opt-in). — additive `@Published calendar` status + `requestCalendarAccess()` using `EKEventStore.requestFullAccessToEvents()` (macOS 14+); existing methods untouched; called only by `EventKitCalendarSink.create` (first use).
- [x] 14.2 Denied/restricted → graceful failure: message + deep-link to System Settings; other commands keep working. — denied returns `false` → `TaskError.calendarPermissionDenied` → executor `.failed`; new `Pane.calendar` deep-link; calendar is NOT in `allRequiredGranted` so it never blocks other commands.
- [x] 14.3 Confirm Accessibility (selection) and Screen Recording (vision) reuse needs no new prompt; vision command reports unavailable if Screen Recording missing. — unchanged from slices 2–3 (selection/vision reuse held grants); no new prompt added on these paths.
- [x] 14.4 Add the EventKit usage-description string to the app's Info.plist. — `NSCalendarsFullAccessUsageDescription` added to `Resources/Info.plist` (the repo plist copied verbatim by `scripts/build-app.sh`).

## 15. Settings UI

- [x] 15.1 Added the `aiCommandsEnabled` opt-in (default OFF; gates band + model download/residency; no native-gesture change / re-login) following the scalar-per-key + `didSet` pattern (`Defaults`/`Keys`/init-load; intentionally excluded from reset like other consent opt-ins). Also `aiSelectedModelID` (nil = registry default).
- [x] 15.2 Added an "AI commands" `Section` in `SettingsView.swift`: the opt-in toggle + caption, a "Manage AI commands…" sheet button, and `ModelManagementView` (selected model, size, lifecycle status/progress, download/retry, evict) bound to an injected `ModelManager`. Store/manager injected as OPTIONAL deps so the existing call site is unchanged. *(Global model-picker writer for `aiSelectedModelID` folded into slice 6.)*
- [x] 15.3 Implemented `Settings/AICommandEditorView.swift`: master/detail add/reorder/delete + per-command inspector (name, icon/tint, input, multi-line prompt with an insertable `{input}/{date}/{app}/{url}` token bar, output + task-kind/destination pickers, model, confirmBeforeRun) mirroring the `FavoritesEditorView` `ItemInspector`; edits persist via `AICommandStore.mutate`.
- [x] 15.4 Older settings decode unchanged with the feature off (no AI keys) — covered by a new AppSettings test (+5 tests, 418 total green).

## 16. Verification, tests, and spec sync

- [x] 16.1 `swift build` + `swift test` green for all core phases (stub runtime): **443 tests / 0 failures** (incl. the canvas-resolution gesture tests). *(MLX `GemmaRuntime` target via `xcodebuild` is the deferred Phase 10.)*
- [x] 16.2 Spec coverage: every new capability has unit tests (LLMRuntime/registry/manager, AICommand/store/template/executor, SelectionService, TaskDispatcher, AICommandBandBuilder, LauncherCanvasMode) and the launcher-overlay deltas are regression-guarded; effectful AX/EventKit/SCK paths are covered by `MANUAL-TEST.md` (not faked).
- [x] 16.3 Consolidated signed-build manual-test checklist written → `openspec/changes/ai-command-band/MANUAL-TEST.md` (selection/AX, swipe-to-resolve commit/discard, tasks + EventKit, vision, model lifecycle, regression sanity).
- [x] 16.4 Updated `README.md` for the feature (30-second brief AI Command Band bullet; Job A "AI commands" opt-in + model download/Apple-Silicon note; B0 capability list → 19 incl. the 4 AI capabilities; B5 `enableAICommands` opt-in + AI tunables) and the `xcodebuild` `GemmaRuntime` target, and `CLAUDE.md` for the runtime/landmines — written now that the real MLX wiring has landed.
- [x] 16.5 `openspec validate` passes (`--strict`); delta specs synced into `openspec/specs/` and the change archived via `/opsx:archive` (4 new capabilities: on-device-ai-runtime, ai-command-band, ai-command-tasks, selection-io; 3 modified: launcher-overlay, tunable-settings, permissions-onboarding).
