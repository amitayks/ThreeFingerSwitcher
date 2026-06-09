# AI Command Band — design exploration (thinking, not a committed change)

> Status: **explore seed.** No proposal/specs/tasks yet. Promote to `openspec/changes/` when ready.

## Context

Clipboard history left us three reusable substrates: **the Band** (non-activating scrub/dwell/lift surface with a master-detail preview pane), **the Hand-off** (capture the front app, act into it via paste/keystroke/AX — `LaunchService.pasteEntry` + `frontAppProvider` + `capturedFrontApp`), and **the Stream/Store** (privacy-aware recorder + on-disk index/blobs). The clipboard band is a *streamed* band. Favorites are *static* bands. The unexplored third kind is **verbs that act on what you're looking at right now** — and the most valuable verb is an LLM.

The AI Command Band is a launcher band whose items are **named AI commands** (curated prompt presets). You scrub to a command, lift, and it takes your current **input** (the text you have selected in the front app, or the clipboard, or an OCR of a screen region), runs it through an on-device model, and routes the **output** somewhere — back into the app in place, or into a background **task** that *does something* (calendar event, save to a project, open a tool with a generated payload, send-to).

The keyboardless identity is the design language, not a limit: you can't type a freeform prompt at use time, so commands are **presets** configured in Settings. The grid of canned verbs *is* the interface.

## Goals / Non-Goals

**Goals:**
- A band of user-configurable AI commands, fired by the existing dwell/lift, non-activating, working in **any** app.
- Two execution modes from one mechanism:
  - **In-place edit** — transform the selection and paste the result back where the user was (fix grammar, make concise, translate, explain, rewrite).
  - **Background task** — interpret the input and *perform an action* without pasting: "add to calendar" (parse a meeting agreement → `EventKit` event), "save to project N" (append/file the highlighted research under a project), "open Claude Code with this idea" (launch a tool with a generated prompt/payload), "send to <destination>".
- **On-device by default** — target the latest Apple Silicon Macs and run a local model (Gemma) for zero cost, full privacy, no network. (Runtime/model choice is its own exploration — see Open Questions and the companion Gemma notes.)
- The **preview pane** (already built for clipboard) becomes the **streaming output canvas**: watch the model's result stream, then resolve it with a fresh four-finger swipe — a **down swipe commits** (paste / run the task), a **horizontal swipe discards** (an up swipe is ignored; a stray re-lift is a no-op).
- Each command is fully **customizable**: name, prompt template, input source, output target, and (for tasks) the action it triggers.

**Non-Goals:**
- No freeform prompt typing at use time (keyboardless). Custom prompts are authored in Settings.
- Not a chat UI. One-shot command → result. (A "send to Claude Code / a chat app" task hands conversation off to a real chat tool.)
- Not cloud-first. A cloud fallback is an explicit, consent-gated option, never the default.
- No autonomous multi-step agents firing irreversible actions without confirmation (see Risks).

## Decisions (proposed)

### The command model
A command is a value type roughly:
```
AICommand {
  name, icon, tint
  input:  .selection | .clipboard | .screenRegionOCR | .none
  prompt: String           // template with tokens: {input}, {date}, {app}, {url?}
  output: .replaceSelection | .pasteAtCursor | .previewOnly
        | .runTask(TaskKind) | .sendTo(Destination)
  model:  .onDevice | .cloud(provider)   // v1 = onDevice (Gemma 4) only
  confirmBeforeRun: Bool   // defaults on for irreversible tasks; user-overridable
}
```
Commands live in a new band kind (`.aiCommand`) or as a configurable band in the favorites editor, persisted like favorites.

### Input via Accessibility selected-text (the key enabler)
Read the front app's selection with AX `AXSelectedText` / `AXSelectedTextRange` (no clipboard clobber; we already hold Accessibility). Fallback: synthesize ⌘C, read pasteboard, then **restore** the prior clipboard. For `.replaceSelection`, set `AXSelectedText` if settable, else paste. This single capability — "what is the user looking at / has highlighted" — underpins this whole band (and the Transforms band). **Note (codebase grounding below): none of the AX selected-text read/replace exists yet — it's the one genuinely new primitive we must build.**

### The preview pane is the latency-and-trust surface
On lift, the band stays open showing the command's preview pane; the model **streams** tokens into it. The user sees the result form before committing. A fresh four-finger **down swipe commits**: pastes for in-place, or runs the task. A fresh four-finger **horizontal swipe discards** (an up swipe is ignored; a stray re-lift while the canvas is open is a no-op). This turns model latency from a wait into a *review*, and makes "it rewrote my text, undo undo" impossible.

### Background tasks reuse existing plumbing + structured output
The "task" modes are the agentic part. The model emits **structured output** (JSON for an action), which we parse and dispatch through machinery we already have or can add thinly:
- **Add to calendar** → `EventKit` (new permission, consent-gated) from a parsed `{title, start, end, attendees, notes}`.
- **Save to project N** → append the text (+ source URL/app) to a per-project note/file (reuses the clipboard store pattern; projects tie into the Workspaces idea, openspec/explore/project-workspaces/design.md).
- **Open Claude Code / a tool with this idea** → `LaunchService` opens the app / runs a script/shortcut with the generated prompt as the payload (e.g. write a prompt file + `open -a`, or a Shortcut).
- **Send to <Slack/Notion/Drive/email>** → a destination adapter (shell-out / Shortcut / URL scheme) fed the (optionally AI-refined) content.
"Send-to" is therefore *not* a separate feature — it's an AI command whose output target is a destination, and the model can refine the text and pick/open the necessary app as part of the task.

### Model strategy — one model now, swappable later (decided 2026-06-08)
- **v1 ships exactly one model: Gemma 4 31B** (the largest, most capable Gemma 4 — text + vision, max reasoning quality), run **in-process via MLX-Swift**. We target the **strongest Apple Silicon only** (M4/M5-class, ample unified memory) and use the best the hardware allows — *no* accommodation for low-end Macs.
- **Build the seam for "many models, swap per task" now, but only wire Gemma 4 for v1.** Every call goes through an `LLMRuntime` protocol so a per-command/per-task model choice (and later Apple Foundation Models / cloud / a future Gemma) drops in without touching feature code. We *test only Gemma 4 models* first; alternates and fallbacks come later.
- **Audio is the one capability the flagship lacks** (see family table): 31B and 26B-A4B are text/vision/video only. When audio verbs land (a later sub-feature), that command routes — via the same seam — to the largest audio-capable Gemma 4 (the 12B). This is exactly what the swap-per-task seam is for.

## Risks / Trade-offs

- **Irreversible actions from a probabilistic model.** Calendar events, sends, file writes must show a **confirmation preview** of the parsed action before firing (the preview pane already exists for this). `confirmBeforeRun` defaults on for any side-effecting task.
- **No freeform prompt at use time.** Mitigated by rich Settings authoring + token templates; the few canned verbs cover the 90%.
- **Model RAM / first-run download (GBs).** Targeted at strong Macs; explicit opt-in + download UX; quantized (QAT 4-bit) weights; keep the model resident between calls or lazy-load with a spinner in the preview.
- **AX selected-text not exposed by every app.** Fallback to ⌘C-with-restore; if even that fails, fall back to clipboard input and `.previewOnly`/paste output.
- **Latency on big models.** The streaming preview makes it tolerable; on the target hardware even the 31B streams faster than reading speed (see numbers below).
- **Privacy of selection → model.** On-device keeps it local (on-brand). A cloud command is a per-command consent gate, clearly labeled.
- **Scope creep into "an agent."** Hold the line at *one-shot command → reviewed result/action*. Multi-step autonomy is out.

## Open Questions

- ~~**Which Gemma + which runtime**~~ → **RESOLVED:** Gemma 4 31B, in-process via **MLX-Swift**; `LLMRuntime` seam for later per-task swap. See model section below.
- ~~**Structured output / tool-calling** strict/validated?~~ → **RESOLVED (path chosen):** **schema-targeted structured output** — target the task schema, validate, and repair/retry on mismatch, with the model free to **decline** ("not applicable"). Grammar-guided decoding (XGrammar via `mlx-swift-structured`) is one optional technique, not a hard cage. Not regex-after-the-fact. See model section.
- ~~**Older-Mac / no-model fallback**~~ → **RESOLVED:** target the newest M4/M5-class Macs only, ship the single best model, no low-end fallback for v1.
- **Confirmation UX** for side-effecting tasks in a non-activating, keyboardless overlay (dwell-to-confirm? a distinct "armed-danger" state?). — still open.
- **Where do commands live** in the editor, and how are prompt templates authored without a heavy text UI? — *informed* by codebase grounding (AppSettings array + a new editor section, or the `FavoritesEditorView` inspector pattern; build a synthetic band on open like clipboard). Authoring-UI shape still open.
- **Multimodal**: Gemma 4 sees images, so `.screenRegionOCR` becomes "screen region → vision model" for "explain this chart / extract this table". yes, this will be a sub featuer to analys screens and scence lateer on. we could wuery "what dose this this products"/how to use that thing.." and so on. (Screen Recording permission is **already held** for thumbnails — see grounding — so screen capture is free.)

---

## Gemma & the on-device model layer — research notes (captured 2026-06-08)

> Snapshot of the on-device model landscape **at the moment this feature was scoped**. Gemma moves *fast* (a full generation jump inside ~12 months), so **re-verify against the model card before building**. These are the "companion Gemma notes" referenced above. Sources at the end.
>
> **Design stance (per owner, 2026-06-08):** We power the app with **Gemma 4** — the whole family is fair game, but **v1 uses one model and tests only Gemma 4**. Everything sits behind a swappable `LLMRuntime` seam so any capable model (a future Gemma, Apple Foundation Models, cloud) can drop in *later*, and so a command can pick a different Gemma 4 size per task (e.g. audio). We aim for the **best result on strong hardware**, not broad-Mac compatibility.

### TL;DR recommendation

- **Engine:** the **Gemma 4** family (Apache-2.0), run **in-process via MLX-Swift** (no sidecar, no daemon — fits an unsandboxed menubar app cleanly).
- **v1 model: Gemma 4 31B (dense)** — the flagship, max reasoning quality (85.2 % MMLU-Pro). Text + vision + video. ~17–20 GB at 4-bit. The right pick when "best result" beats "lightest footprint" and the Mac is strong.
- **Speed alternative (only if interactive latency disappoints): Gemma 4 26B-A4B (MoE, ~3.8 B active)** — near-31B quality (82.6 %) at noticeably higher tok/s. Same modalities (no audio). Keep it in our pocket; the seam makes switching trivial.
- **Audio (later, via the seam): Gemma 4 12B** — the *largest* audio-capable variant. 31B/26B do **not** take audio.
- **Structured output: schema-targeted + validate/repair** (model may decline; XGrammar via `mlx-swift-structured` optional) for task JSON.
- **Deferred (not v1):** Apple Foundation Models (zero-download macOS-26 alternate) and any cloud provider — behind the same seam.

### The Gemma 4 family

Encoder-free multimodal decoder-only transformers. Architectural highlights:
- **No separate vision/audio encoders.** Vision enters via a lightweight embedding (single matmul + positional + norm); raw 16 kHz audio is projected straight into the text token space. Smaller weights, simpler pipeline, one model for all its modalities.
- **Multi-Token Prediction (MTP) drafters** built in → self-speculative decoding → lower latency (helps our streaming preview pane).
- **140 languages**, Apache-2.0, **QAT** (quantization-aware-trained) 4-bit checkpoints published alongside the base weights.
- Google also shipped an **official Skills/agentic repo** for Gemma 4.
- **Release timeline (verify):** core family (E2B/E4B/26B-A4B/31B) launched ~**2026-04-02**; the **12B** dense, "first mid-sized model with native audio, runs in 16 GB", followed ~**2026-06-03**.

| Variant | Active / Total | Modalities | Context | 4-bit size | MMLU-Pro | Role for us |
|---|---|---|---|---|---|---|
| E2B | 2.3 B | text · vision · **audio** · video | 128K | ~3.6 GB | 60.0 % | (too small) |
| E4B | 4.5 B | text · vision · **audio** · video | 128K | ~5 GB | 69.4 % | small audio option |
| 12B (dense) | 12 B | text · image · **audio** | 256K | ~8 GB* | n/a* | **audio verbs (later)** |
| 26B-A4B (MoE) | 3.8 B / 26 B | text · vision · video | 256K | ~14 GB | 82.6 % | **speed alternative** |
| **31B (dense)** | 30.7 B | text · vision · video | 256K | ~17–20 GB | **85.2 %** | **★ v1 default** |

\* 12B 4-bit size / MMLU-Pro not firmly pinned in sources — verify. **⚠ Audio caveat:** audio input is **E2B / E4B / 12B only**. The two highest-quality variants (26B-A4B, 31B) are **text + image + video, no audio**. Audio clips ≤ 30 s; video sampled (≤ 60 s).

**Rough speed (31B dense, Q4, tok/s):** M4 Max ~40–50 · M4 Pro 36 GB ~20–35. The MoE 26B-A4B is materially faster (only ~3.8 B active). Human reading ≈ 4–5 tok/s, so **even the 31B streams several× faster than the user reads** → the "latency-as-review" preview-pane bet holds comfortably on our target hardware.

### Why Gemma 4 fits *this* feature (capability → leverage)

```
 Gemma 4 capability                →  AI Command Band use
 ─────────────────────────────────────────────────────────────────────
 Encoder-free native vision         →  .screenRegionOCR becomes a real
                                       vision query: "what is this
                                       product / how do I use this thing"
                                       — one model, screenshot + prompt.
                                       (Screen Recording perm already held.)
 Schema-targeted JSON               →  the BACKGROUND-TASK modes: model
   (validate/repair, declinable)       returns add_to_calendar{…} /
                                       save_to_project{…} / send_to{…} —
                                       or declines; we validate + dispatch
                                       (EventKit, LaunchService, adapter)
                                       + review (default-on, overridable).
 MTP drafters + MLX in-process      →  fast streaming → preview = review.
 256K context (26B / 31B)           →  whole-document inputs, multi-file
                                       "save to project" summarization.
 Native audio (12B / E4B)           →  later voice verbs, reached via the
                                       seam (31B itself has no audio).
 Apache-2.0                         →  ship / bundle weights, commercial-OK.
```

### Running it on Apple Silicon — runtime options

| Option | Shape | Pros | Cons / gotchas |
|---|---|---|---|
| **MLX-Swift, in-process** ★ | Swift package linked into the app | No daemon, native, fastest on Apple Silicon, unified-memory streaming, fits unsandboxed menubar app | Must build w/ `xcodebuild` (Metal shaders) |
| **LiteRT-LM sidecar** | `litert-lm serve` → OpenAI-compatible localhost | Google's official agentic stack + Skills; OpenAI API | Extra process to ship/manage |
| **Ollama sidecar** | local daemon, OpenAI API | Trivial model mgmt; **MLX-powered on Apple Silicon since 03/2026** | ~10–20 % slower than raw MLX; another process |
| **llama.cpp / GGUF** | sidecar/lib | Ubiquitous; GBNF grammar-constrained JSON | Slower than MLX on M-series |

**Chosen: MLX-Swift in-process.** Building blocks that already exist:
- `ml-explore/mlx-swift-lm` — official LLM+VLM Swift lib.
- `VincentGourbin/gemma-4-swift-mlx` — **native Gemma 4 multimodal (text+vision+audio+video) for Apple Silicon**. API surface: `Gemma4Pipeline`, `ChatSession`, `chatStream(prompt:)` → `for try await token in stream`, plus LoRA + speculative decoding + a `Gemma4TokenFilter` for thinking-mode. Requires macOS 14+, Swift 6, Xcode 16, **`xcodebuild` (not `swift build`)** for Metal.
- `petrukha-ivan/mlx-swift-structured` — **grammar-guided decoding for MLX-Swift** (XGrammar): grammar-based generation, JSON-Schema → `Decodable`, a `@Generable`-style typed path, **streaming `PartiallyGenerated`**, and tool-call handling. We treat this as **one optional technique**; the default path is target-the-schema + validate/repair so the model keeps latitude to decline.

### Structured output / tool-calling — the agentic backbone

**Decision: schema-targeted output, validate-and-repair, let the model decline — don't cage the decoder.** Each `TaskKind` (`add_to_calendar`, `save_to_project`, `open_tool_with_payload`, `send_to`) is one JSON schema. We ask the model for output matching it, then **validate and repair/retry on mismatch** before decoding into a Swift `Decodable`, and we let the model **decline ("not applicable")** rather than fabricate values to satisfy the schema. Hard grammar-caging is a **latent footgun** — it degrades content and forces invented fields — so we treat constrained decoding (`mlx-swift-structured`, XGrammar) as **one optional technique** for the cases that benefit, not a mandatory cage on every call. This still sidesteps brittle regex parsing of Gemma's native tool-call tokens (incomplete in mlx-swift-lm #259) by targeting a schema and validating.

We **validate and (by default) show an action-review preview** before executing any side-effecting task; `confirmBeforeRun` **defaults on** for side effects but is **user-overridable**. The model's job ends at "produce the structured result or decline"; *we* own validation, dispatch, and the review gate.

### Deferred alternates (behind the same seam — not v1)

- **Apple Foundation Models** — built into macOS 26+ (no download, free, always present, ~3 B). `@Generable` macro → type-safe guided generation, built-in tool calling, stateful sessions, a few lines of Swift. Far less capable / less multimodal than big Gemma 4. Future role: the zero-download fallback and simplest in-place edits — *not* the v1 engine.
- **Cloud provider** — consent-gated per command, clearly labeled. Later.
- **Tiny on-device router** — a sub-1B model could pre-classify which command/task an input wants and cheaply extract the call before waking the big model. Model-agnostic, deferred; the seam supports it.

### The swappable model layer (the "any capable model" requirement)

Everything hides behind one seam. Sketch (design, not code):

```
protocol LLMRuntime {
  var capabilities: Set<Modality>        // .text .vision .audio
  func stream(_ req: LLMRequest) -> AsyncThrowingStream<Token, Error>
  func structured<T: Decodable>(_ req: LLMRequest, schema: Schema) async throws -> T
}

GemmaMLXRuntime   : LLMRuntime   // v1 — gemma-4-swift-mlx + mlx-swift-structured
AppleFMRuntime    : LLMRuntime   // later — Foundation Models, @Generable
CloudRuntime      : LLMRuntime   // later — consent-gated
```

`AICommand.model` selects the runtime; for v1 it always resolves to `GemmaMLXRuntime`. A `ModelManager` owns download / residency / eviction and (later) **per-task model selection** — e.g. an audio command asks for `.audio` capability and gets the 12B instead of the 31B. **No feature code references Gemma directly** — only `LLMRuntime`. Adding a model later = one conformer.

### Open risks specific to the model layer

- **Model residency / load time** — even on a strong Mac, a ~17–20 GB model has a cold-load cost; lazy-load with a "loading model" preview state, keep resident between calls, evict on memory pressure.
- **First-run download UX** — multi-GB (QAT 4-bit); explicit opt-in, resumable, verified (sha). Apple FM (later) could cover the gap while it downloads.
- **Audio capability gap** — the flagship 31B has no audio; audio verbs must route to 12B/E4B via the seam. Bake the capability check into `ModelManager` from the start so it's not a retrofit.
- **Version churn** — Gemma cadence is fast; the `LLMRuntime` seam + a model registry (id → size/sha/url/caps) keep upgrades off the feature code.
- **`swift build` won't compile MLX** (needs Metal/`xcodebuild`) — clashes with CLAUDE.md's "verify with `swift build`" rule; the model layer needs a stubbed `LLMRuntime` for unit tests and a separate `xcodebuild` verification path.

---

## Codebase grounding — what we reuse vs. what we build (mapped 2026-06-08)

Read against `Sources/ThreeFingerSwitcher/`. The three substrates are real and reusable; only the AX selected-text primitive and the model layer are genuinely new.

### The Band (UI surface) — reuse, extend with one new kind
- **Non-activating overlay:** `SwitcherPanel(NSPanel)`, `canBecomeKey/Main = false`, `[.borderless, .nonactivatingPanel]` — `Overlay/OverlayController.swift:112`. Launcher recreates its panel per `show()` bound to the current Space — `Overlay/LauncherOverlayController.swift:206`.
- **Dwell / lift:** `LauncherModel` holds `arming`/`armed` + `armingToken`; dwell is a `DispatchWorkItem` re-armed on every move (`LauncherOverlayController.swift:175`, `:191`); **lift fires only if `armed`** and hides the panel *before* firing (`:76`). Haptic on arm (`:201`).
- **Preview pane = the streaming canvas:** `Overlay/ClipboardBandView.swift` is the master-detail (left 340 px key list + right value pane). Async content already updates via `.task(id:)` — **that is exactly the hook for streaming model tokens** into the right pane.
- **Band kinds are a flat enum, not a protocol:** `enum LaunchItemKind: Codable` (8 cases) — `Launcher/LaunchItem.swift:165`; `ContextBand` is a value type (`:215`). The clipboard band is **synthetic**, built fresh on open by `Clipboard/ClipboardBandBuilder.swift` and detected by a sentinel UUID.
- **Extension points for our band:** (1) add `case .aiCommand(AICommand)` to `LaunchItemKind`; (2) add a fire branch in `Launcher/LaunchService.swift:47`; (3) render icon in `Overlay/LauncherView.swift:108`; (4) for the preview-canvas, add a conditional band view in `LauncherView.body` (mirror the `currentBandIsClipboard` branch) and build a synthetic AI band on open like `ClipboardBandBuilder`. Wire-in point: `AppCoordinator.swift:372`.

### The Hand-off (input/output into the front app) — mostly reuse, **one missing primitive**
- **Paste back:** `LaunchService.pasteEntry()` = NSPasteboard write → `app.activate()` → `postKey(⌘V, toPid:)` with a 40 ms settle (`Launcher/LaunchService.swift:74`). Deliberately paste, not AX-set — paste is universal.
- **Front-app capture:** `AppCoordinator.capturedFrontApp` + injected `frontAppProvider` (`AppCoordinator.swift:41`,`:48`); `postKey()` CGEvent synth posts per-pid (`LaunchService.swift:354`).
- **AX is already used** for windows/menus/geometry via `axCopy/axString` (`AXPrivate.swift:15`) and `AXUIElementCreateApplication`.
- **⚠ MISSING (build this):** reading **`kAXSelectedTextAttribute`** off `AXFocusedUIElement`, the **`AXSelectedText` set / replace**, and a **clipboard save-restore** helper for the ⌘C fallback. None exist today. This is the core new primitive (call it `SelectionService`).
- **Permissions:** Accessibility is **already held** (so AX selected-text read is "free"); **Screen Recording is already held** for thumbnails (so `.screenRegionOCR` vision is "free"); Input Monitoring held — `PermissionsService.swift:19`. New permission needed only for **EventKit** (calendar task).

### The Stream/Store + authoring — reuse the patterns
- **On-disk store pattern:** `Clipboard/ClipboardStore.swift` = Codable JSON index + externalized blobs (>16 KB) under `~/Library/Application Support/…`, content-hash names. Reuse this shape for "save to project" output.
- **Structured user config:** `Favorites` = one Codable JSON blob in `UserDefaults` via `FavoritesStore.mutate()` (`Launcher/FavoritesStore.swift:31`). `AppSettings` = `@MainActor ObservableObject`, scalar-per-key UserDefaults with `didSet` persist (`Settings/AppSettings.swift`).
- **Command authoring:** persist `[AICommand]` as a `@Published` array on `AppSettings` (encode in `didSet`), OR a dedicated store if it grows. Editor: a new section in `Settings/SettingsView.swift`, or reuse the kind-specific **`ItemInspector`** pattern in `Settings/FavoritesEditorView.swift:587` (it already does per-kind config UIs — the model for editing prompt template / input source / output target).

### Build/verify caveat
MLX needs Metal → must build via `xcodebuild`, not `swift build`. Keep the model behind `LLMRuntime` with a stub conformer so the rest of the feature still verifies under the project's `swift build`/`swift test` rule (CLAUDE.md).

### Sources (verify before building — captured 2026-06-08)

- Gemma 4 launch — blog.google "Introducing Gemma 4 12B" / "Gemma 4: byte-for-byte most capable open models"; deepmind.google/models/gemma/gemma-4
- Family/specs — ai.google.dev/gemma/docs/core + model_card_4; HF google/gemma-4-{31B,26B-A4B,12B,E4B}; audio-modality: dev.to "Gemma 4's Audio and Video Inputs" + HF model cards
- Function calling — ai.google.dev/gemma/docs/capabilities/text/function-calling-gemma4
- Apple Silicon / Swift — gemma4.dev MLX guide; sudoall.com Apple-Silicon benchmarks; github VincentGourbin/gemma-4-swift-mlx, ml-explore/mlx-swift-lm (incl. issue #259), **petrukha-ivan/mlx-swift-structured** (XGrammar constrained decoding)
- Apple FM — developer.apple.com/documentation/FoundationModels
