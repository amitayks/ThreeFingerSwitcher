## Context

The AI feature is built on five `AICommand` knobs (input → prompt template → model → output) fired keyboardlessly from the launcher, with the result streamed into a preview canvas that commits on a four-finger down-swipe. Today the entire **text** path is live — `selection`/`clipboard`/`none` input, `replaceSelection`/`pasteAtCursor`/`previewOnly` output, and all four task sinks (calendar/save-to-project/open-tool/send-to) are real. Two paths are modeled but inert: **vision** (`GemmaMLXRuntime.generate` refuses image requests with `unsupportedModality(.vision)`) and the richer **task** verbs are unseeded. Authoring exposes only `AIBand.seeded()` (6 commands) and a single blank "Add AI Command" button, while peer sources (`ActionBrowser` over `SystemAction`) are browsable one-click catalogs.

This change closes those gaps: a catalog that mirrors the Actions browser, the runtime language picker the user asked for, native bidirectional canvas text, working vision, and two new task sinks.

## Goals / Non-Goals

**Goals:**
- Make the Bands-editor AI source a **browsable, categorized catalog** of ~50 ready-made commands; one click to add a preset, or add a whole category as a band.
- Grow the fresh-install seed (still one curated band).
- A **runtime language parameter**: pick/repick the target language *in the canvas*, re-translate in place, and persist the choice for next time.
- Render the canvas **RTL/LTR natively** (first-strong base direction per paragraph; clean mixed-direction resolution).
- Implement **vision** in the v1 Gemma conformer so `screenRegion` commands run.
- Add **Reminders** and **Contacts** task sinks to complete the catalog's capture verbs.

**Non-Goals:**
- Audio modality, cloud models (both stay reserved behind the existing seam).
- **Per-app / contextual auto-selection** of AI bands (`ContextBand` has no app association today; that is a separate future change).
- Typing a free-form language at fire time (the picker is a fixed dropdown — keyboardless).
- Generalizing runtime parameters beyond `language` in v1 (the type is extensible; only `.language` ships).
- Translating the app's own UI chrome.

## Decisions

### D1 — Catalog as a static `[AICommand]` table, not an enum
`SystemAction` is an enum because each case maps to imperative code. An AI command is **pure data** — name, icon, tint, input, template, output. So the catalog is a `AICommandCatalog` value table of `(category: Category, command: AICommand)` literals, where `Category` is a `CaseIterable` enum carrying `(title, symbol)`. The browser mirrors `ActionBrowser`: a `List` grouped by category, each row a button that calls `onPick(AIBand.item(for: preset))`. Each add **mints a fresh `UUID`** (the catalog template's id is a stencil, never the live id) so the same preset can be added twice and identities stay unique. Rationale: zero new execution machinery — presets ride the existing executor unchanged; the catalog is just better defaults.

- *Alternative considered:* an enum like `SystemAction`. Rejected — it would force a parallel data model for values that `AICommand` already holds, and block user-tweaking after add.

### D2 — Add-one and add-category-as-band; keep a blank custom entry
The browser offers per-row add **and** a per-category "Add all as a band" (creates a `ContextBand` named after the category, color from the category). A trailing **"Custom command…"** entry preserves today's blank-then-edit flow. Rationale: the gesture punishes giant bands (you scrub icons by dwell); the real value is composing small purpose-built bands, so adding a curated category as a band is the primary affordance.

### D3 — Runtime parameter modeled on the command, resolved via a `{lang}` token
Add `var runtimeParameter: RuntimeParameter?` to `AICommand` (Codable, default `nil`). v1: `enum RuntimeParameter { case language(default: String) }`. The prompt template gains a `{lang}` token resolved to the **active** language (the canvas selection, falling back to the persisted last-choice, falling back to the parameter default). Translate presets use a template like `"Translate the following to {lang}. Return only the translation:\n\n{input}"` with `runtimeParameter: .language(default: "English")`. Rationale: keeps the command a self-describing value; the canvas and executor read one field; templating stays unit-testable.

- *Alternative considered:* one command per language. Rejected — band clutter and no in-run repick.

### D4 — Persist the last language **per command**, in AppSettings
The chosen language persists as `[commandID: String]` in `AppSettings` (UserDefaults-backed), written when the user repicks in the canvas, and read at fire time to seed the canvas's initial selection. Rationale: the user explicitly wants "save my chosen lang to the next run"; per-command (not global) so a "to Hebrew" and a "to Spanish" command can coexist and each remembers its own. The command's stored `default` is the cold-start fallback; persistence never mutates the stored command (so catalog/seed stay stable and the value survives band edits).

### D5 — Re-run reuses cancellable generation; canvas stays open
Repicking a language **cancels the in-flight generation** (existing `RuntimeError`-clean cancellation, which is not a failure) and starts a new generation with the re-resolved prompt, streaming into the same canvas. The output target is unchanged — commit (down-swipe) applies whatever is current; discard (horizontal) cancels. Rationale: reuses the existing cancellable streaming contract; no new resolution state.

### D6 — Bidirectional text via natural base writing direction
SwiftUI `Text` already runs the Unicode Bidi algorithm *within* a string, but defaults the **base** paragraph direction to the LTR environment, so a Hebrew paragraph renders left-aligned with trailing punctuation misplaced. The canvas's output/echo/review fields render with **natural (first-strong) base writing direction per paragraph** — via a TextKit/`NSTextView` path with `baseWritingDirection = .natural` for the selectable streaming output, and first-strong detection driving `.multilineTextAlignment`/`layoutDirection` where SwiftUI `Text` is used. Base direction is **recomputed as tokens stream** (the first strong character can arrive late). Mixed LTR+RTL within a paragraph is left to the system Bidi resolver. Rationale: "natural" is exactly the first-strong rule the user wants ("Hebrew starts from the correct place"), and it makes mixed text resolve cleanly without per-run configuration.

### D7 — Vision: build a new image-aware generation path against the multimodal primitives
`GemmaMLXRuntime` currently loads the **text-only** graph (`multimodal: false`) and refuses images. The model is vision-capable, but — importantly — **there is no ready image-aware call to swap to**: `Gemma4Pipeline.chatStream(prompt:…)`/`chat(…)` are text-only (`String` prompt, no image/pixelValues parameter), as the runtime's own header comment notes. The real multimodal path in the dependency is **hand-rolled in its CLI** (`Gemma4CLI.swift`): load the multimodal model, run `Gemma4ImageProcessor.processImage`, expand the `<|image|>` placeholder and splice `imageTokenId` tokens, `register(multimodal: true)`, set `pendingPixelValues`, then a manual prefill + autoregressive generate loop (non-streaming). So this task is a **non-trivial new image-aware generation path**, not a one-line route change. **Architecture decision (post-code-audit):** `Gemma4Pipeline`'s `container` is **private** and `chatStream` is text-only, so the vision path cannot reuse the text pipeline's loaded model — it must own a **separate `ModelContainer`** loaded with `Gemma4Registration.register(multimodal: true)` + `loadModelContainer(from:)` (replicating the CLI's `loadLocalMultimodalModel`, which is in the CLI target and not importable). This means a vision-capable runtime holds **two resident graphs** (the text pipeline + the multimodal container, ~2× weights in unified memory). That is **acceptable for v1 precisely because** the runtime "Targets capable hardware only" (no low-end path; ample unified memory is a stated precondition). The multimodal container is **lazily loaded on first vision request** (text-only users never pay it) and kept resident thereafter. v1 is **image-only** (the `LLMRequest` carries one optional image; video/audio token paths are ignored).
The plan: (a) when the selected registry model advertises `.vision` and a request carries an image, drive a new image-aware generate path against the separate multimodal container — process the PNG via `Gemma4ImageProcessor` → pixel values, build the prompt with one `<|image|>`, `applyChatTemplate`, expand the image token to `boi + image×numImageTokens + eoi` (the CLI pattern), set `model.pendingPixelValues`, and run a manual generate loop; (b) buffer that (non-streaming) output into the `AsyncThrowingStream`. Capability-based selection already maps `screenRegion → .vision`. The text fast path (text-only `chatStream`) is preserved for non-image commands so they pay no multimodal load/memory cost. **Streaming caveat:** the manual multimodal path is not streaming today; v1 MAY land vision as a non-streaming generate that fills the canvas on completion (the canvas already shows a loading state), with incremental streaming as a follow-up if the upstream pipeline gains an image-bearing stream method. Rationale: contained to the MLX target and below the `LLMRuntime` seam (everything above already treats vision as supported), but scoped honestly as new generation code rather than an API swap.

### D8 — Reminders/Contacts mirror the calendar task exactly
Two new `TaskKind` cases (`.addToReminder`, `.newContact`), each with a `Parsed…` declinable schema (`applicable`+`reason`+fields) and a sink behind a protocol (testable; production = `EKReminder` via EventKit, `CNContact`+`CNSaveRequest` via Contacts). Action-review (`confirmBeforeRun` default ON) and the error taxonomy are reused; `TaskError` gains a generalized `permissionDenied(name:)` (or per-case) so the "points to the fix" recovery message can name Reminders/Contacts. Rationale: the task layer is designed for exactly this additive shape.

## Risks / Trade-offs

- **One-giant-band misuse** → catalog defaults to category-scoped adds + a curated small seed; the per-row add stays but the category-as-band is primary.
- **Replace-in-place hallucination** → the output-target default per preset follows three principles (the canvas down-commit always reviews first — `replaceSelection` only writes after the user reads the streamed result and deliberately swipes down, so "in place" is never *unreviewed*):
  1. **Commentary / derivative output is always `previewOnly`** — Explain, Summarize, TL;DR, Define, Pros & Cons, Proofread, Explain-anything. The output is *about* the input, not a replacement *for* it, so it must never overwrite the selection.
  2. **Long or structural output is `previewOnly`** even though it's a "replacement", because subtle hallucination hides in it and can't be eyeballed in the streaming canvas — all **code** rewrites (Add Docstring, Rewrite in Language, Regex, Shell), JSON↔YAML, and extracted lists.
  3. **Short, fully-eyeball-reviewable replacements default to `replaceSelection`** — grammar, tone, concision, whitespace/format cleanups, and an explicitly-named **"Translate in Place"** (the translation is short enough to verify in the canvas before the down-commit; the primary **"Translate"** stays `previewOnly`). This is the user's core Hebrew↔English workflow and is safe because of the review-then-commit gate.
- **RTL base direction flips mid-stream** as the first strong char arrives → recompute on each streamed update; accept a one-time minor reflow rather than guessing.
- **Vision memory/load cost** (multimodal graph is heavier) → gate multimodal load to vision requests; keep the text-only fast path resident for text commands.
- **New permissions** (Reminders, Contacts) → consent-gated at first use only, never at launch; denial surfaces the existing non-blocking failed-state-with-pointer; usage-description strings added (App Sandbox stays off, so no new entitlement).
- **Free-form `{lang}` value** → constrained to a fixed dropdown list (no typed input), so the substituted value is always a known language string.

## Migration Plan

- Catalog and the new sinks are **purely additive**; no data migration. Existing users keep their authored bands untouched.
- Seed growth affects **fresh installs only** — the existing migration/idempotency guard in `AIBand`/Favorites schema is unchanged (an upgrading user does not get re-seeded).
- `{lang}` is a new known token; existing templates without it are unaffected (unknown-token rules already pass through).
- Vision is behind capability selection + the opt-in/download gate; no behavior change for users who never fire a `screenRegion` command.
- Rollback: the catalog/runtime-parameter/RTL/sinks are independent slices behind the `LLMRuntime` seam and can be reverted individually; vision reverts to the refuse path.

## Open Questions

- Exact membership of the grown seed (which ~8–10 of the ~50 catalog entries) — resolve during the catalog task.
- Cold-start default language for Translate presets: ship `"English"` and let per-command persistence override (assumed yes).
- (Resolved) "Add category as a band" **always appends** a new band even if one with the same name exists — the Bands editor already allows rename/merge, and dedupe would surprise a user who wants a second copy. Now normative in the catalog spec.
- (Resolved by codebase audit) Vision is **not** an existing-call swap — see D7; the runtime needs a new image-aware generate path built on the dependency's multimodal primitives, and v1 may be non-streaming.
