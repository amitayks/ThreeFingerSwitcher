## Context

The launcher overlay is a non-activating, keyboardless, dwell-to-arm / lift-to-commit surface that already (a) captures the front app before it shows, (b) reuses the held Accessibility permission to act into that app, and (c) hosts a *static* band (Favorites) and a *streamed* band (Clipboard, a master-detail with a live value preview). This change adds a third kind: a band of **named AI commands** that take the user's current input (selected text / clipboard / screen region), run it through an **on-device Gemma 4 model**, and route the output either back in place or into a side-effecting task.

Two things make this newly viable. First, **Gemma 4** (Apache-2.0; core family ~2026-04, 12B-with-audio ~2026-06) is a frontier-class open model that runs **in-process on Apple Silicon via MLX-Swift** — fast enough to stream faster than reading speed on M4/M5-class hardware. Second, **schema-targeted structured output for MLX-Swift** (with XGrammar via `mlx-swift-structured` available as one technique) lets the task modes return typed JSON we **validate and, on mismatch, repair** — a reliable typed result without caging the model token-by-token. Full research is captured in `openspec/explore/ai-command-band/design.md`; this document records the decisions that flow from it.

Codebase grounding (verified 2026-06-08): the overlay panel (`Overlay/OverlayController.swift`), dwell/lift (`Overlay/LauncherModel.swift`, `LauncherOverlayController.swift`), the master-detail preview (`Overlay/ClipboardBandView.swift`, which already updates async via `.task(id:)`), the synthetic-band pattern (`Clipboard/ClipboardBandBuilder.swift`), paste-on-fire (`Launcher/LaunchService.swift:74`), front-app capture (`App/AppCoordinator.swift`), AX helpers (`AXPrivate.swift`), and settings (`Settings/AppSettings.swift`, `SettingsView.swift`, `FavoritesEditorView.swift`) all exist and are reused. The only genuinely new primitives are **AX selected-text read/replace** and the **model layer**.

## Goals / Non-Goals

**Goals:**
- A new launcher band whose items are user-configured AI commands, fired by the existing dwell/lift, non-activating, in any app.
- One mechanism, two output modes: **in-place edit** (transform selection → paste/replace) and **background task** (schema-targeted structured output → reviewed side effect).
- The preview pane becomes a **live streaming output canvas**: stream → fresh four-finger **down swipe commits**, **horizontal swipe discards**.
- An **on-device model layer** behind a swappable `LLMRuntime` seam, with **Gemma 4 31B via MLX-Swift** as the only v1 conformer; structured output that is **schema-targeted and validated (repair-on-mismatch, declinable)**; model **download/residency lifecycle**.
- A keyboardless-friendly **command authoring** UI in Settings, opt-in (default OFF), targeting the **strongest Apple Silicon only**.

**Non-Goals:**
- No freeform prompt typing at use time (authored in Settings).
- Not a chat UI; one-shot command → reviewed result/action. No multi-step autonomous agent.
- Not cloud-first; cloud is a later, consent-gated alternate behind the same seam.
- No low-end-Mac fallback, no second/router model, no Apple-Foundation-Models or cloud conformer in v1 (the seam exists for them; they are not built now).
- Audio-input commands are out of v1 scope (the flagship 31B has no audio; audio routes to the 12B *later* via the seam).

## Decisions

### D1 — Single model, swappable seam: Gemma 4 31B via MLX-Swift, in-process
All model access goes through a `LLMRuntime` protocol (`capabilities`, streaming `generate`, `structured<T: Decodable>`, vision input). v1 wires exactly one conformer, `GemmaMLXRuntime`, backed by `VincentGourbin/gemma-4-swift-mlx` (+ `ml-explore/mlx-swift-lm`). The default model is **Gemma 4 31B** (dense, text+vision, 85.2% MMLU-Pro, ~17–20 GB at QAT 4-bit) — the best quality the target hardware allows.
- **Why in-process MLX over a sidecar (Ollama/LiteRT-LM):** no second process to ship/lifecycle/secure, fastest path on Apple Silicon (unified memory, no GGUF overhead), clean for an unsandboxed menubar app, native streaming into the preview.
- **Why 31B over 26B-A4B (MoE):** the owner prioritizes quality over speed on strong hardware. 26B-A4B (near-31B quality, faster) is documented as the drop-in if interactive latency disappoints — switching is a one-line `ModelManager` change because of the seam.
- **Alternatives considered:** Ollama sidecar (rejected: extra process, ~10–20% slower); LiteRT-LM serve (rejected for v1: extra process; revisit if we want its agentic Skills); Apple Foundation Models (rejected as primary: far less capable/multimodal; kept as a *future* conformer); cloud (rejected as default: privacy is the brand).

### D2 — Structured output: schema-targeted, validated, and repairable (not caged)
Task modes ask the model for JSON matching a task's schema, then **validate the result and repair/retry on mismatch** (a small bounded loop) before decoding into a Swift `Decodable`. The model keeps full latitude to reason in free text first and to **decline / signal "not applicable"** when the input doesn't fit the task. Grammar-guided decoding (`petrukha-ivan/mlx-swift-structured`, XGrammar) is available as **one optional technique** for the cases that benefit, not a mandatory cage applied to every call.
- **Why not hard-constrain every call:** rigid token-masking is a latent footgun — it degrades answer quality and **forces the model to fabricate** values to satisfy the grammar (inventing a meeting time where the text has none) rather than admitting "this isn't a meeting." Validate-and-repair keeps structure reliable while letting the model decline; the human-visible review is the real safety net. (We still avoid brittle regex-only parsing of Gemma's native tool-call tokens — incomplete in mlx-swift-lm #259 — by targeting a schema and validating.)
- **Alternatives considered:** hard grammar-caging every task call (rejected: the rigidity footgun above — worse content and forced fabrication); prompt-and-regex-parse `<|tool_call|>` tokens (rejected: brittle). Schema-target + validate/repair + decline sits deliberately between them.

### D3 — Input via Accessibility selected-text, with ⌘C-restore fallback
A new `SelectionService` reads `AXSelectedText` off the focused element of `capturedFrontApp` (no clipboard clobber, reusing held Accessibility). If unavailable, it synthesizes ⌘C, reads the pasteboard, then **restores the prior pasteboard contents**. For `.replaceSelection` output it sets `AXSelectedText` when settable, else falls back to the existing paste-on-fire (`LaunchService`). Screen-region input uses ScreenCaptureKit (Screen Recording already held) → image into the vision model.
- **Why AX-first:** non-destructive, instant, no focus change. **Why keep ⌘C fallback:** many apps don't expose settable/readable AX selection; ⌘C-with-restore is the universal floor (the same realism the clipboard feature accepted).

### D4 — The preview pane is the latency-and-trust surface (swipe-to-resolve)
On lift, firing an AI command does **not** dismiss the overlay; it opens the command's preview canvas and streams tokens in. Resolution is a **fresh four-finger swipe**: a **down swipe commits** (paste/replace, or run the task — "bring the result down into the document"), a **horizontal swipe discards**, an **up swipe is ignored**; focus stays on the captured app throughout. Side-effecting tasks insert an extra **armed-confirmation state** showing the *parsed action* (e.g. the calendar event fields) before the commit swipe.
- **Why a swipe and not a "second lift":** the firing gesture already raised the fingers, so there is no lift left to "release" — re-touching and lifting felt dead in testing. A fresh directional swipe is unambiguous and gives commit a physical metaphor (down = into the document) distinct from discard (sideways). The recognizer runs a one-shot **canvas-resolution mode** (`launcherCanvasResolutionActive`, set from the canvas open/close state) that interprets the next four-finger swipe as a single `launcherCanvasResolve(dx:dy:)`, bypassing the normal launcher/switcher latch; a re-lift while the canvas is open is a no-op.
- **Why this surface at all:** makes model latency a review, makes a bad rewrite un-committable, and gives irreversible actions a mandatory preview. Reuses `ClipboardBandView`'s async `.task(id:)` update path as the streaming hook. A down swipe before the result is committable is ignored (the user waits); a horizontal discard is honored at any time, including mid-stream.
- **Alternative considered:** fire-and-paste immediately with undo (rejected: undo across arbitrary apps is unreliable; a probabilistic model writing into the user's doc with no review is the "undo undo" nightmare). Also considered "second lift commits" (rejected: fingers are already up after firing).

### D5 — Commands are a value type, authored in Settings, built into a synthetic band on open
`AICommand { id, name, icon, tint, input, prompt, output, model, confirmBeforeRun }` (Codable). Persisted as a `@Published [AICommand]` on `AppSettings` (encoded in `didSet`), mirroring how Favorites/settings persist. On launcher open, `AICommandBandBuilder` projects the configured commands into a synthetic `ContextBand` of `.aiCommand` items (mirroring `ClipboardBandBuilder`); the band is **never written into the Favorites record**. Authoring reuses the `FavoritesEditorView` kind-specific `ItemInspector` pattern for editing name/prompt-template/input/output/model/confirm.
- **Why a synthetic band:** commands are config, not Favorites items; building on open keeps a single source of truth and avoids dual persistence (the clipboard band proved this pattern).
- **Prompt templates** use tokens `{input}`, `{date}`, `{app}`, `{url}` resolved at fire time from the captured context.

### D6 — Tasks: schema-targeted JSON → dispatcher → reviewed side effect (review default-on, user-overridable)
Each `TaskKind` (`add_to_calendar`, `save_to_project`, `open_tool_with_payload`, `send_to`) has a JSON Schema; the model produces a result that the dispatcher **validates (repairing/retrying on mismatch) or treats as a decline**; a `TaskDispatcher` then renders the parsed action; on commit it executes: EventKit (calendar), an on-disk note append reusing the clipboard store pattern (project), a generated payload file + `LaunchService open` or a Shortcut (open-tool), or a destination adapter — Shortcut / URL scheme / shell-out — (send-to). `confirmBeforeRun` **defaults to true** for side-effecting tasks but the system **honors the user's stored value** — a user may turn confirmation off for a trusted task, in which case the task commits without the extra action-review step (the baseline deliberate commit down-swipe still applies).

### D7 — Opt-in, strong-hardware-only, build-isolated runtime
The feature is gated by an "AI commands" opt-in (default OFF) that also unlocks the multi-GB model download. We target M4/M5-class Macs and use the best model available; there is no degraded mode for weaker hardware. The MLX runtime compiles only under `xcodebuild` (Metal), so the model layer lives behind `LLMRuntime` with a **stub conformer** that keeps the rest of the feature building/testing under the project's `swift build` / `swift test` rule.

## Risks / Trade-offs

- **Irreversible action from a probabilistic model** → an action-review state before side effects, **default-on for side-effecting tasks but user-overridable**; schema validation + repair (and the model's ability to decline rather than fabricate) keep the parsed action well-formed without caging the decoder; the baseline deliberate commit down-swipe still guards against accidental fires even when review is off.
- **Multi-GB first-run download / cold-load latency** → opt-in + resumable, integrity-verified download; lazy load with a "loading model" preview state; keep resident between calls; evict on memory pressure.
- **AX selected-text not exposed by every app** → ⌘C-with-restore fallback; if even that fails, fall back to clipboard input and `.previewOnly`/paste output (never silently do nothing).
- **MLX target won't compile under `swift build`** → `LLMRuntime` seam + stub conformer; the runtime target is verified separately via `xcodebuild`.
- **Model/runtime version churn (Gemma cadence is fast)** → a model registry (id → size/sha/url/capabilities) and the seam keep upgrades off the feature code.
- **Privacy of selection/screen → model** → on-device only in v1; any future cloud command is a per-command, labeled consent gate.
- **Scope creep into "an agent"** → hold at one-shot command → reviewed result/action; no multi-step autonomy.
- **Latency on 31B** → acceptable: on target hardware it streams several× faster than reading; 26B-A4B MoE is the documented fallback if not.

## Migration Plan

- Purely additive; default OFF. No existing behavior changes when the opt-in is off; older settings decode unchanged (new keys default to off/empty). No data migration.
- New SwiftPM dependencies (`gemma-4-swift-mlx`, `mlx-swift-lm`, `mlx-swift-structured`) are linked only by the runtime target; the build invokes `xcodebuild` for that target (documented in README/CLAUDE.md build notes).
- New permission (Calendar/EventKit) is requested lazily at first calendar-task use, never at launch; Accessibility and Screen Recording are already granted.
- Rollback: toggling the opt-in off disables the band, recorder, and model residency immediately; uninstalling the model frees the weights. No irreversible system changes (no native-gesture relocation, no re-login).

## Open Questions

- **Authoring UX for prompt templates** without a heavy text editor in a keyboardless app — dedicated Settings window vs. inline inspector; token insertion affordance. (Shape open; persistence/location decided.)
- **Confirmation gesture** for the armed-confirmation state — RESOLVED (D4): confirmed by the same fresh four-finger DOWN swipe that commits, discarded by a horizontal swipe; the open sub-question is only how to make "danger" legible.
- **Default command set** shipped on first enable (the canned verbs that cover the 90%): exact list and prompts.
- **Eviction policy** specifics (idle timeout vs. memory-pressure only) and whether to preload on opt-in vs. on first use.
