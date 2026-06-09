## Context

The AI Command Band runs an on-device Gemma 4 model via MLX. An audit of all 48 error sites across its
four layers (provision/download, executor/runtime, tasks/selection, UI) found the error handling is
strong in the middle (the `AICommandExecutor` and `TaskDispatcher` funnel failures through clean
`message(for:)` mappers; `TaskError` is a proper `LocalizedError`; `TaskReview` never throws;
cancellation is correctly not-a-failure) but **leaks raw errors at both ends** and **disagrees with
itself** because the same error is formatted differently per surface.

Two user-visible bugs both trace to one violated rule — *never interpolate a raw error into a
user-bound string*:

- `ModelManager.swift:170` / `:234`: `state = .failed(reason: "Failed to provision …: \(error)")`. Offline,
  `error` is the wrapped `NSURLError`, so `\(error)` is the giant Domain/Code/UserInfo dump.
- `ModelManagementView.swift:63`: `Text(reason)` with no cap, inside `SettingsView`'s `Form` pinned to
  `.frame(width: 460, height: 460)` with no `ScrollView` (`SettingsView.swift:186-187`) — it overflows.
- `AppCoordinator.swift:591`: the alert path tries `(error as? LocalizedError)?.errorDescription ?? "\(error)"`,
  but `RuntimeError` (`LLMRuntime.swift:124`) does **not** conform to `LocalizedError`, so it also falls
  back to raw — and it is presented via app-modal `NSAlert.runModal()` (`AppCoordinator.swift:1123`),
  whose nested run loop is what freezes the Settings window.

Beyond the two bugs, the audit surfaced: `GemmaMLXRuntime.prepare` re-throwing the raw `Gemma4DownloadError`
across the boundary; a missing generic catch in `ModelManager`'s byte-download path (`:183-186` only catches
`CancellationError`, so a real download error leaves the state stuck at `.downloading`); and several
**silent-success** paths that report a false "Done" (`NSWorkspace.open` fire-and-forget, ignored `Process`
termination status, `replaceSelection`/`pasteAtCursor` reporting *attempted* not *landed*, swallowed
AX/screen-capture failures).

## Goals / Non-Goals

**Goals:**
- Every user-facing AI error surface (Settings status row, any alert, the overlay canvas) shows a **concise,
  human-readable** message, identical across surfaces for the same error.
- Raw error text is available **on demand** (copyable details / disclosure / logs) but never inline-unbounded.
- The Settings window stays **interactive** during and after any AI error (no app-modal block, no overflow).
- No AI state machine can get **stuck** on an unhandled error; no side effect reports success unless it landed.
- The fix is **systemic** (one taxonomy, one translator, boundary mapping) so new error sites inherit it.
- Preserve the existing good behavior: the executor/dispatcher funnels, `TaskError`, `TaskReview`-never-throws,
  cancellation-as-not-a-failure, and the swappable `LLMRuntime` seam.

**Non-Goals:**
- No change to the vendored `Gemma4DownloadError` (lives in `.build/checkouts`); it is mapped, not edited.
- No new download/retry strategy, no model changes, no new permissions or dependencies.
- Not a general app-wide error framework — scoped to the AI feature (`AI/`, `GemmaRuntime`, and the AI parts
  of Settings/Overlay/AppCoordinator). The other `runModal()` call sites (file pickers, user-initiated
  confirmations) are out of scope; only app-modal *error surfaces* for background failures change.
- Localization/i18n of the messages is out of scope (English strings, matching the rest of the app).

## Decisions

### D1 — Extend `RuntimeError`, add `LocalizedError`, add one central translator (accepted)
Rather than introduce a parallel error type, extend the existing `RuntimeError` (`LLMRuntime.swift:124`)
with the missing cases — `offline`, `serverUnavailable`, `authOrAccessDenied`, `modelLoadFailed` — and make
`RuntimeError: LocalizedError`, whose `errorDescription` returns exactly the clean strings already
hand-written in `AICommandExecutor.message(for:)`. Add a single translator:

```
enum AIError {
    static func message(for error: Error) -> AIPresentedError
}
struct AIPresentedError { let headline: String; let details: String? }
```

`message(for:)` resolves the headline in priority order: (1) the app's own `LocalizedError`
(`RuntimeError`, `TaskError`) `errorDescription`; (2) a classifier for vendor/OS errors —
`Gemma4DownloadError` by case (and, for `.networkError`, inspecting the wrapped `(e as NSError).code`
to split `offline` from `serverUnavailable`), bare `NSError` by domain/code; (3) the `.unknown` fallback
("Something went wrong."). The raw `String(describing:)` is stashed as `details` (never the headline).
This collapses the four existing mappers onto one implementation and removes the two-surface inconsistency
by construction.
- **Why extend rather than add a new type:** least churn, one place for runtime errors, and existing
  consumers that already `switch` on `RuntimeError` keep working. The thin `AIPresentedError(headline,details)`
  carries the UI shape without bloating the runtime enum.
- **`Equatable` constraint:** `RuntimeError` is `Equatable`; new cases must stay `Equatable`. The
  copyable raw text rides on `AIPresentedError.details` (derived at translation time), not as a stored
  non-`Equatable` `Error` payload — so `RuntimeError` stays `Equatable` with simple associated values
  (e.g. `offline`, `serverUnavailable`, `authOrAccessDenied`, `modelLoadFailed(detail: String?)`).

### D2 — Map at the layer boundary, propagate typed within a layer
Raw vendor/OS errors are converted to the taxonomy where they cross into app code:
- `GemmaMLXRuntime.prepare` catch: convert `Gemma4DownloadError` → matching `RuntimeError` case, load
  failures → `.modelLoadFailed`, keep `CancellationError` → `.cancelled`. Keep the `String(describing:)`
  **log** line; stop letting the raw error escape. After this, only `RuntimeError` crosses into `ModelManager`.
- `ModelManager.downloadAndVerify` / `loadIfNeeded`: replace `\(error)` with `AIError.message(for: error)`
  (headline into `.failed(reason:)`, details stashed for the UI). Add the missing generic catch on the byte
  path so a non-cancel error sets `.failed` symmetrically instead of hanging at `.downloading`.

### D3 — Failure is observable state; alerts are belt-and-suspenders, not the primary surface
Keep the `.failed`-state pattern. For Settings-scoped model failures, the in-window `.failed` row (with its
existing **Retry** button) is the primary surface; the redundant app-modal `NSAlert.runModal()` on the
download path is removed (or, if any alert remains, it is **window-modal** via `beginSheetModal(for:)` so it
never starves the window). This kills the freeze at its source.

### D4 — Detail is opt-in; UI is bounded and scroll-safe
The clean one-line headline renders. The raw `details` live behind a collapsed "Show details" disclosure with
a "Copy" button. Any potentially-long error `Text` gets `.lineLimit` + `.truncationMode(.middle)` +
`.textSelection(.enabled)`. `SettingsView`'s `Form` content is wrapped so variable-length content degrades to
scrolling, never to a frozen/overflowed window (the fixed `460×460` frame must not be the only bound).

### D5 — Failure ≠ silence
Make the silent-success paths honest: wrap `DiskProjectStore` `FileManager`/`FileHandle` throws in
`TaskError`; surface real failure from `NSWorkspace.open` (completion handler), `Process` (terminationStatus),
and the URL-scheme branch; have `replaceSelection`/`pasteAtCursor` report whether the write actually landed,
and surface `permissionDenied` for AX/Screen-Recording gaps instead of letting them masquerade as `noInput`.
A path that didn't accomplish its effect produces a `.failed` state, not a `.committed`/"Done".

### D6 — Honor the swappable-`LLMRuntime` seam
The taxonomy + translator live in Core (alongside `RuntimeError` in `LLMRuntime.swift`). Each backend
(GemmaMLX today; Apple Foundation Models / cloud later) maps **its** native errors to the shared taxonomy at
its own boundary, so feature/UI code only ever sees the taxonomy regardless of backend.

## Risks / Trade-offs

- **NSError-code sniffing for offline.** Splitting `offline` vs `serverUnavailable` from
  `Gemma4DownloadError.networkError` means inspecting `(wrappedError as NSError).code`
  (`NSURLErrorNotConnectedToInternet` / `-1005`). Mitigation: classification is centralized in `AIError`
  and covered by unit tests over synthetic `NSError`s; optionally classify at the downloader throw site later.
- **Touching many files.** The change spans provision → runtime → tasks → selection → UI. Mitigation: it is
  mostly *substitution* (raw interpolation → translator call) plus additive `LocalizedError` conformance; the
  existing tests guard the funnels, and new tests pin the taxonomy and the offline classification.
- **Cross-change overlap with `ai-command-band`.** Both touch the AI files. Mitigation: this change is purely
  hardening (no behavior the feature spec describes is removed); it can land before or after `ai-command-band`
  is archived. If `ai-command-band` is synced first, the rendering rules here can be cross-referenced from
  those capabilities.
- **Captive portal nuance.** A captive portal (HTTP 200 + HTML) currently lands in `parseError`, not
  `networkError`, so it won't say "offline." Accepted for v1; the `unknown`/`serverUnavailable` message is
  still clean and bounded. (Open question whether to re-classify it as a connectivity hint.)
- **Removing the alert could feel "too quiet."** Dropping the app-modal alert relies on the in-window
  `.failed` row being visible. Mitigation: it is shown in the same panel the user just acted in, with a Retry
  button; this is the conventional, non-blocking pattern and matches the existing comment calling the alert
  "belt-and-suspenders."

## Open Questions

- For `RuntimeError.modelLoadFailed` / `offline`, do we need a `detail: String?` payload (kept `Equatable`)
  so `AIError` can attach copyable raw text, or is deriving `details` purely in `AIError.message(for:)`
  (from the original `Error` before it becomes a `RuntimeError`) sufficient? (Leaning: derive in the
  translator; only `modelLoadFailed` carries an optional detail string.)
- Where exactly should `AIError` live so both the `GemmaRuntime` module and the app target can use it
  without a layering violation? (`Core/LLMRuntime.swift` is shared and visible to both — likely there or a
  sibling `AIError.swift` in Core.)
- Should the swallowed-success correctness fixes (D5) and the offline-classification share one PR/slice or be
  sequenced? (User chose comprehensive scope, so: same change, separate task groups/slices.)
