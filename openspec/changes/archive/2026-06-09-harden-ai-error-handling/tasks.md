# Tasks — harden-ai-error-handling

Build/verify rule (per CLAUDE.md): Core changes verify with `swift build` / `swift test`; the
`GemmaRuntime` (MLX) target and the app verify with `xcodebuild`. Do not assemble/install the `.app`.

## 1. Taxonomy + central translator (Core)

- [x] 1.1 In `Sources/ThreeFingerSwitcher/AI/LLMRuntime.swift`, extend `RuntimeError` with the missing cases: `offline`, `serverUnavailable`, `authOrAccessDenied`, `modelLoadFailed(detail: String?)`. Keep the enum `Equatable` (associated values stay `Equatable`; no stored non-`Equatable` `Error`).
- [x] 1.2 Conform `RuntimeError: LocalizedError`; implement `errorDescription` for **every** case, reusing the clean strings currently hand-written in `AICommandExecutor.message(for:)` (lines ~307–315) so no message regresses.
- [x] 1.3 Add `Sources/ThreeFingerSwitcher/AI/AIError.swift` defining `struct AIPresentedError { let headline: String; let details: String? }` and `enum AIError { static func message(for error: Error) -> AIPresentedError }`.
- [x] 1.4 Implement `AIError.message(for:)` resolution order: (a) app `LocalizedError` (`RuntimeError`, `TaskError`) → `errorDescription` as headline; (b) vendor/OS classifier (see 1.5); (c) `.unknown` fallback headline "Something went wrong." Always stash `String(describing: error)` as `details` (never as headline) except where a cleaner detail exists.
- [x] 1.5 Implement the vendor/OS classifier inside `AIError`: bare `NSError` by domain/code (`NSURLErrorDomain` connectivity codes → `offline`; `5xx` → `serverUnavailable`; `401/403/404` → `authOrAccessDenied`), shared via the `public` `runtimeError(forHTTPStatus:)` helper; `CancellationError`/`RuntimeError.cancelled` → benign "Cancelled." headline. NOTE on `Gemma4DownloadError`: Core is MLX-free and cannot import the vendor package, so per design D6 the `Gemma4DownloadError` → `RuntimeError` mapping lives at the `GemmaMLXRuntime` boundary (task 2.1) and REUSES `AIError`'s HTTP classifier — `AIError` itself never sees the vendored type. The vendored type is untouched.
- [x] 1.6 `AIError` lives in `ThreeFingerSwitcherCore` (visible to BOTH `GemmaRuntime` and the app — no layering violation), documented in the file header. `import` graph confirmed: `GemmaRuntime` builds against `AIError.runtimeError(forHTTPStatus:)` (xcodebuild compile-verify, task 7.5).

## 2. Boundary mapping (GemmaRuntime / provision)

- [x] 2.1 In `Sources/GemmaRuntime/GemmaMLXRuntime.swift` `prepare(model:progress:)` generic catch: convert `Gemma4DownloadError` → matching `RuntimeError` case (via the new `runtimeError(for:)` mapper, which sniffs the wrapped `NSError` code on `.networkError` and reuses `AIError.runtimeError(forHTTPStatus:)`), pipeline/load failures → `RuntimeError.modelLoadFailed(detail:)`, keep `CancellationError` → `RuntimeError.cancelled`, and a pre-mapped `RuntimeError` passes through. Stops re-throwing the raw error; KEEPS the `String(describing:)` diagnostic log line.
- [x] 2.2 (Optional, cleaner) Intentionally NOT done at the downloader: the offline split is centralized in the `GemmaMLXRuntime.runtimeError(for:)` mapper (it sniffs the wrapped `NSError` code), which is the documented primary path; a downloader-side offline signal would be redundant. The file-private sentinels (`Fatal/RetryableHTTP`, `ShortRead`) remain internal and are never surfaced raw (they're caught and converted to `Gemma4DownloadError`/`RuntimeError` before crossing the boundary).
- [x] 2.3 Verified: the only errors now crossing out of `prepare` are `RuntimeError` (and `CancellationError`, which `ModelManager` catches as `is CancellationError`); `HubDownloader.download` throws `RuntimeError.unavailable`. No vendor/OS error escapes the runtime.

## 3. ModelManager — de-leak + state robustness

- [x] 3.1 `ModelManager` provision catch: now `state = .failed(reason: AIError.message(for: error).headline, details: AIError.message(for: error).details)`. `ModelLifecycleState.failed` was extended to `failed(reason: String, details: String? = nil)` so the lifecycle state carries the copyable details the UI reads.
- [x] 3.2 `ModelManager` load catch: same substitution (clean headline + stashed details).
- [x] 3.3 Byte-download path: added a generic `catch` (after `catch is CancellationError`) that sets `.failed` with the translated headline + details, so a non-cancel error can never leave the state stuck at `.downloading`.
- [x] 3.4 Confirmed: the clean hardware/integrity reasons remain clean fixed strings (they're the template) and slot into the same `.failed(reason:details:)` shape with `details: nil`.

## 4. Executor + dispatcher — consolidate onto one translator

- [x] 4.1 `AICommandExecutor.message(for:)` is now a one-liner `AIError.message(for: error).headline`; the old `?? "\(error)"` fallback is gone — `AIError` returns the safe generic "Something went wrong." for an unrecognized error, so a raw dump can never reach the canvas.
- [x] 4.2 `TaskDispatcher.message(for:)` now routes through `AIError.message(for:).headline`; `prepare()`'s never-throw contract is intact (the `couldNotProduceValid` interception keeps its task-specific "Couldn't produce a valid action." phrasing before the translator is reached).
- [x] 4.3 Cancellation handling unchanged: the executor stream still returns on `RuntimeError.cancelled`/`CancellationError`, and commit paths treat cancellation as not-a-failure.
- [x] 4.4 Reviewed: `commit()` still sets `.failed` (the real surface, with the clean headline) AND rethrows; the `try?` at `AppCoordinator.swift` deliberately swallows the rethrow because the state already records it. The existing `testReviewedCommitThatThrowsSurfacesFailedWithHumanMessage` pins this. No change needed.

## 5. Tasks / selection — failure is never silent (D5)

- [x] 5.1 `TaskSinks.swift`: the three `error.localizedDescription` interpolations inside `TaskError.sinkFailed` are replaced with clean fixed messages; the raw inner error is now logged to a file-private `os.Logger` (`taskSinkLog`) and never put in the user-facing string.
- [x] 5.2 `WorkspaceToolOpener.open` now uses a THROWING open handler; `defaultOpen` awaits the async `NSWorkspace.open(...)` (surfacing a failed open) and checks `shortcuts run` `terminationStatus`. `AdapterDestinationSender`: malformed URL-scheme and a failed `NSWorkspace.open(url)` throw `TaskError.sinkFailed`; `runProcess` checks `terminationStatus != 0` (the authoritative success signal — a tolerated broken-pipe stdin write alone is not treated as failure).
- [x] 5.3 `DiskProjectStore.append` now wraps its `FileManager`/`FileHandle` throws in `TaskError.sinkFailed` at the IO boundary (mirroring the calendar sink), so disk-full/permission never dumps a raw `NSError` through the executor fallback.
- [x] 5.4 `SelectionService`: READ path keeps nil-on-failure (legit clipboard fallback); `pasteAtCursor` now returns `Bool` (landed) like `replaceSelection`; the executor maps a non-landed `replaceSelection`/`pasteAtCursor` to `.failed` with a clean message instead of `.committed`.
- [x] 5.5 `SelectionService.captureScreenRegion` now returns a `ScreenCaptureOutcome` (`.captured`/`.permissionDenied`/`.unavailable`); a Screen-Recording gap surfaces a `.failed` that NAMES the permission + points at System Settings, instead of masquerading as `.noInput`. (AX is an app-wide baseline grant: its READ gap legitimately falls back to clipboard, and its SET gap surfaces via the non-landed-write path in 5.4.)

## 6. UI hardening

- [x] 6.1 `ModelManagementView` `.failed` row: renders the concise headline as primary (`.lineLimit(3).truncationMode(.middle).fixedSize(horizontal:false, vertical:true).textSelection(.enabled)`) plus a collapsed "Show details" `DisclosureGroup` (bounded `ScrollView`, maxHeight 120) with a "Copy details" button bound to the stashed `details`.
- [x] 6.2 `SettingsView`: the grouped `Form` is scroll-safe — the frame is now flexible (`maxHeight: .infinity`) and the Settings window is `.resizable`, so variable-length content degrades to scrolling/resizing instead of overflowing the fixed `460×460` frame.
- [x] 6.3 `AppCoordinator.downloadAIModel` catch: the app-modal `infoAlert` error surface is REMOVED; the in-window `.failed` row + Retry is the only surface. Cancellation is caught as not-a-failure; other errors are logged (no `runModal()` background-error surface remains).
- [x] 6.4 N/A — no alert path is kept for AI errors (6.3 removed the only one). The in-window row builds its message from the same `AIError` translator (via `ModelManager`'s `.failed(reason:details:)`).
- [x] 6.5 `AICommandCanvasView` `.failed`/`.declined`: both messages now carry `.lineLimit(6).truncationMode(.middle)` so a long message/reason can't overflow the panel.
- [x] 6.6 Confirmed: only the AI download `infoAlert` call was removed; the `infoAlert` helper and every non-AI `runModal()` site (file pickers, MC-restore confirmations) are untouched.

## 7. Tests + verification

- [x] 7.1 `Tests/.../AIErrorTests.swift`: `AIError.message(for:)` over synthetic `NSError`s (offline `-1009`, dropped `-1005`, 5xx, 401/403/404) and over `RuntimeError`/`TaskError`/`CancellationError`/unknown — asserts clean headlines (no `Domain=`/`Code=`/`UserInfo`) and that `details` carries the raw text.
- [x] 7.2 `AIErrorTests`: every `RuntimeError` case has a non-empty `errorDescription`; the offline message asserts a connectivity hint; `decodeFailed`'s raw detail is kept off the headline.
- [x] 7.3 `ModelManagerTests`: a thrown non-cancel (offline `NSError`) download → ends `.failed` with the clean connectivity headline (never stuck `.downloading`); a `CancellationError` → `.notDownloaded`, no failure.
- [x] 7.4 Honesty tests: `AICommandExecutorTests` — a non-landed `replaceSelection`/`pasteAtCursor` → `.failed`; a `TaskError.sinkFailed` thrown on commit → clean verbatim message; a `.permissionDenied` capture → `.failed` naming Screen Recording. `TaskDispatcherTests` — an injected failing `WorkspaceToolOpener` open handler surfaces `TaskError.sinkFailed`.
- [x] 7.5 Full Core suite green: `swift test` → 464 tests, 0 failures. MLX target + app: `xcodebuild -scheme ThreeFingerSwitcher` → **BUILD SUCCEEDED** (boundary-mapping edits compile).
- [x] 7.6 `MANUAL-TEST.md` added under the change dir (offline enable → clean row + interactive Settings + Retry; airplane-mode mid-download; cancellation; calendar-denied; failed tool open; screen-recording gap; long-message layout; same-message-everywhere). User runs it in the signed build.

## 8. Docs + spec sync

- [x] 8.1 The error-handling convention (one taxonomy, one translator, ban raw interpolation, map at boundary, failure-as-state/never-silent, non-blocking bounded UI) is documented in `CLAUDE.md`'s AI section; `README.md` already points to this change as the clean+non-blocking follow-up.
- [x] 8.2 `openspec validate harden-ai-error-handling --strict` passes; delta synced (new `ai-error-handling` capability created in `openspec/specs/`, 7 requirements / 14 scenarios; `validate --specs` 22/22) and the change archived.
