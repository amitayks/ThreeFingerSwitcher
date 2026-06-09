# Tasks — harden-ai-error-handling

Build/verify rule (per CLAUDE.md): Core changes verify with `swift build` / `swift test`; the
`GemmaRuntime` (MLX) target and the app verify with `xcodebuild`. Do not assemble/install the `.app`.

## 1. Taxonomy + central translator (Core)

- [ ] 1.1 In `Sources/ThreeFingerSwitcher/AI/LLMRuntime.swift`, extend `RuntimeError` with the missing cases: `offline`, `serverUnavailable`, `authOrAccessDenied`, `modelLoadFailed(detail: String?)`. Keep the enum `Equatable` (associated values stay `Equatable`; no stored non-`Equatable` `Error`).
- [ ] 1.2 Conform `RuntimeError: LocalizedError`; implement `errorDescription` for **every** case, reusing the clean strings currently hand-written in `AICommandExecutor.message(for:)` (lines ~307–315) so no message regresses.
- [ ] 1.3 Add `Sources/ThreeFingerSwitcher/AI/AIError.swift` defining `struct AIPresentedError { let headline: String; let details: String? }` and `enum AIError { static func message(for error: Error) -> AIPresentedError }`.
- [ ] 1.4 Implement `AIError.message(for:)` resolution order: (a) app `LocalizedError` (`RuntimeError`, `TaskError`) → `errorDescription` as headline; (b) vendor/OS classifier (see 1.5); (c) `.unknown` fallback headline "Something went wrong." Always stash `String(describing: error)` as `details` (never as headline) except where a cleaner detail exists.
- [ ] 1.5 Implement the vendor/OS classifier inside `AIError`: map `Gemma4DownloadError` by case (`networkError` → inspect `(wrapped as NSError).code`: `NSURLErrorNotConnectedToInternet (-1009)`/`-1005` → `offline`, else `serverUnavailable`; `httpError 401/403/404` → `authOrAccessDenied`; `httpError 5xx`/`apiFailed` → `serverUnavailable`; `parseError` → `serverUnavailable`/unknown); bare `NSError` by domain/code; `CancellationError`/`RuntimeError.cancelled` → treated as not-a-failure by callers (translator may still return a benign headline). Reference `Gemma4DownloadError` by its public shape only — do NOT edit the vendored type.
- [ ] 1.6 Decide + document the home of `AIError` so both `GemmaRuntime` and the app target can use it without a layering violation (Core is visible to both). Confirm `import` graph compiles for `GemmaRuntime`.

## 2. Boundary mapping (GemmaRuntime / provision)

- [ ] 2.1 In `Sources/GemmaRuntime/GemmaMLXRuntime.swift` `prepare(model:progress:)` generic catch (≈ lines 94–97): convert `Gemma4DownloadError` → matching `RuntimeError` case, pipeline/load failures → `RuntimeError.modelLoadFailed(detail:)`, keep `CancellationError` → `RuntimeError.cancelled`. Stop re-throwing the raw error; KEEP the `String(describing:)` diagnostic log line.
- [ ] 2.2 (Optional, cleaner) In `Sources/GemmaRuntime/GemmaResumableDownloader.swift` terminal catches, detect `NSURLErrorNotConnectedToInternet`/`-1005` and throw an offline-flavored signal so the mapper need not sniff NSError codes. Keep file-private sentinels (`Fatal/RetryableHTTP`, `ShortRead`) internal; never surface them raw.
- [ ] 2.3 Verify the only error type that now crosses out of the runtime into `ModelManager` is `RuntimeError`.

## 3. ModelManager — de-leak + state robustness

- [ ] 3.1 `Sources/ThreeFingerSwitcher/AI/ModelManager.swift:170` (provision catch): replace `state = .failed(reason: "Failed to provision …: \(error)")` with `state = .failed(reason: AIError.message(for: error).headline)`; stash `AIError.message(for:).details` where the lifecycle state / UI can read it (extend `ModelLifecycleState.failed` to optionally carry `details`, or expose a sibling property).
- [ ] 3.2 `ModelManager.swift:234` (load catch): same substitution as 3.1.
- [ ] 3.3 `ModelManager.swift` byte-download path (≈ :183–186, currently only catches `CancellationError`): add a generic catch that sets `.failed` with the translated headline, so a non-cancel error can never leave the state stuck at `.downloading`.
- [ ] 3.4 Confirm the clean hardware/integrity reasons (`:143`, `:194`, `:223`) remain clean and route through the same headline style (they are the template — keep).

## 4. Executor + dispatcher — consolidate onto one translator

- [ ] 4.1 `Sources/ThreeFingerSwitcher/AI/AICommandExecutor.swift`: replace the body of `message(for:)` (≈ :302–316) with a call to `AIError.message(for:).headline`; fix the `?? "\(error)"` fallback so a non-`LocalizedError` can never dump into the canvas.
- [ ] 4.2 `Sources/ThreeFingerSwitcher/AI/Tasks/TaskDispatcher.swift`: replace `message(for:)` (≈ :181–192) with the central translator; keep `prepare()`'s never-throw contract (failures still become clean `TaskReview.unavailable/.declined`).
- [ ] 4.3 Keep cancellation handling exactly as-is (executor stream + commit paths treat `CancellationError`/`RuntimeError.cancelled` as not-a-failure).
- [ ] 4.4 Review `commit()`'s rethrow vs the `try?` at `AppCoordinator.swift:139`: ensure the `.failed` state is the real surface and the swallowed rethrow doesn't hide anything (the state already records it).

## 5. Tasks / selection — failure is never silent (D5)

- [ ] 5.1 `Sources/ThreeFingerSwitcher/AI/Tasks/TaskSinks.swift`: replace the raw `error.localizedDescription` interpolations inside `TaskError.sinkFailed` (≈ :109, :227, :302) with a clean prefix + the translator for the inner error's detail; log the inner error.
- [ ] 5.2 `TaskSinks.swift` `WorkspaceToolOpener.open` / `AdapterDestinationSender.send`: stop swallowing real failures — surface failed `NSWorkspace.open` (use the completion handler / check result), non-zero `Process` `terminationStatus`, broken-pipe stdin writes, and malformed URL-scheme as `TaskError.sinkFailed`/`taskFailed`.
- [ ] 5.3 `Tasks/TaskDispatcher.swift` `execute(_:)`: wrap `DiskProjectStore.append` `FileManager`/`FileHandle` throws in `TaskError.taskFailed`/`sinkFailed` (like the calendar path) so disk-full/permission stops dumping a raw NSError via the executor fallback.
- [ ] 5.4 `Sources/ThreeFingerSwitcher/AI/SelectionService.swift`: keep nil-on-failure for the READ path (legit clipboard fallback), but make `replaceSelection`/`pasteAtCursor` report whether the write actually landed; have the executor map a non-landed write to `.failed` instead of `.committed` (executor ≈ :250/:253 currently discard the result).
- [ ] 5.5 `SelectionService.swift`: surface `permissionDenied` for Screen-Recording / AX gaps (`captureScreenRegion`, AX read/set) instead of letting them masquerade as `noInput`, so the canvas message names the missing permission.

## 6. UI hardening

- [ ] 6.1 `Sources/ThreeFingerSwitcher/Settings/ModelManagementView.swift:60–64` (`case .failed`): render the concise headline as primary; cap with `.lineLimit(3).truncationMode(.middle).fixedSize(horizontal:false, vertical:true)`; add a collapsed "Show details" `DisclosureGroup` (bounded `ScrollView`) + a "Copy details" button bound to the stashed `details`.
- [ ] 6.2 `Sources/ThreeFingerSwitcher/Settings/SettingsView.swift:186–187`: make the `Form` content scroll-safe (wrap in `ScrollView` or make the window resizable) so variable-length content degrades to scrolling, never overflowing the fixed `460×460` frame.
- [ ] 6.3 `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift:585–593` (`downloadAIModel` catch): remove the redundant app-modal `infoAlert` error surface for the download path (the in-window `.failed` row + Retry is primary). If any alert remains for AI prep, present it window-modal via `beginSheetModal(for: settingsWindow)` and drop `NSApp.activate(ignoringOtherApps:)` for that path — never `runModal()` as a background-error surface.
- [ ] 6.4 If an alert path is kept anywhere for AI errors, build its body from `AIError.message(for:).headline` (same string as the status row).
- [ ] 6.5 `Sources/ThreeFingerSwitcher/Overlay/AICommandCanvasView.swift` (`.failed`/`.declined`, ≈ :101–107): apply the same length cap for symmetry so a future translator-fallback can't overflow the panel.
- [ ] 6.6 Confirm the non-AI `runModal()` call sites (file pickers / user-initiated confirmations) are untouched — only background AI *error* surfaces change.

## 7. Tests + verification

- [ ] 7.1 Unit-test the taxonomy + classifier: `AIError.message(for:)` over synthetic `NSError`s (offline `-1009`, dropped `-1005`, 5xx, 401/403/404) and over `RuntimeError`/`TaskError` cases → assert clean headlines and that `details` carries the raw text, headline never does.
- [ ] 7.2 Unit-test `RuntimeError: LocalizedError` — every case has a non-empty `errorDescription`; assert the offline message is the connectivity hint.
- [ ] 7.3 Unit-test `ModelManager`: a thrown non-cancel error during download → state ends `.failed` with a clean headline (never stuck `.downloading`); a `CancellationError` → `.notDownloaded`, no failure.
- [ ] 7.4 Unit-test the selection/tasks honesty: a non-landed `replaceSelection` → `.failed`; a sink throw → clean `taskFailed`; an `NSWorkspace.open`/`Process` failure → surfaced (use injected fakes / the existing `TaskDispatching` seam).
- [ ] 7.5 Run the full Core suite (`swift test`) green; build the MLX target + app (`xcodebuild`) to verify the boundary-mapping edits compile.
- [ ] 7.6 Add/refresh a manual-test checklist (offline enable → clean status row + interactive Settings + Retry; airplane-mode mid-download; calendar-denied; a task whose tool open fails) under `openspec/changes/harden-ai-error-handling/MANUAL-TEST.md`. (User runs it in the signed build.)

## 8. Docs + spec sync

- [ ] 8.1 Note the error-handling convention (one taxonomy, one translator, ban raw interpolation, map at boundary, non-blocking bounded UI) in `CLAUDE.md` / the agent `README.md` so new AI code inherits it.
- [ ] 8.2 `openspec validate harden-ai-error-handling --strict` passes; after implementation, run `/opsx:sync` + `/opsx:archive`.
