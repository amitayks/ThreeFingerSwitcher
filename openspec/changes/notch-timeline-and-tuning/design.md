# Design — notch-timeline-and-tuning

## Context

The runtime seam already streams two tagged channels (`Token.channel = .thinking | .response` in `AI/LLMRuntime.swift`), and `NotchSessionEngine` already consumes them — but flattens them into two disconnected strings: `@Published thinking` (one flat accumulator, rendered as a single collapsible pinned *after* the whole message list) and `state = .conversing(partial:)` (the answer bubble). Per-message `AgentMessage.thinking` is persisted but never rendered, so history loses its reasoning. In the **routed** path (`runRoutedTurn`, the production path once tools are wired), `AgentLoop` exposes both `onThinking` and `onResponseToken` sinks but the engine wires only `onThinking` — the answer never streams; it lands whole at settle.

For tuning: `aiReasoningEnabled` is snapshot per session at `startNew()`/`bind()` (the exact "applies to new conversations" semantic), but it is a **global** Hub toggle shared with the launcher band; the context budget is **not wired at all** for the notch engine (`makeNotchSessionEngine` passes no `budgetProvider` → hardcoded `DefaultContextBudget()` = 8192), even though `AgentContextPreset`/`AgentContextBudgetProvider` exist and the Hub surfaces them.

Constraints inherited from the codebase: the panel is non-activating (key only while the composer is focused); teardown stays synchronous on the ghost-on-Space-switch paths; no repeating animation that isn't visibility-gated (idle-CPU-spin postmortem); persistence growth must be decode-safe optionals (no schema bump); **`text` is the only re-fed content — thinking is display-only and structurally excluded from assembly** (`AgentConversation.swift` invariant, `ChatTemplate` echo).

## Goals / Non-Goals

**Goals:**
- The expanded transcript is a **timeline**: every assistant turn (live and historical) renders its thinking and answer as interleaved segments in token-arrival order; the live turn streams both channels token-by-token — including the routed path's answer.
- A notch-native **settings zone** (gear above "+ New chat" → the same panel morphs into settings mode) with **one slider** over ordered thinking+context stops, persisted, applied to each **new** conversation until changed.
- Tuning is **born-with**: a conversation carries the (reasoning, context-tokens) it was created under for its whole life.

**Non-Goals:**
- Interleaving **tool steps** into the persisted timeline (the current-turn tool-step list stays as-is; a follow-up can fold them in).
- Touching the runtime seam, the channel classifier, or the launcher AI band / voice surfaces.
- Any Hub redesign — the Hub's global reasoning/context controls remain for the other surfaces; the notch slider is the notch's own dial.
- A per-conversation (retroactive) tuning editor — the slider shapes *future* conversations only.

## Decisions

**D1 — Segments are a display-only, decode-safe extension of `AgentMessage`.** `TurnSegment { kind: .thinking | .answer; text }` (Codable/Equatable/Sendable, Core); `AgentMessage.segments: [TurnSegment]?` optional. Assembly (`assembleRequest`/`ChatTemplate`) continues to read `text` only — segments join `thinking` in the display-only tier. `text` and flat `thinking` are still written on settle, so older builds and existing readers see exactly what they saw before. A message with `segments == nil` (pre-change history) renders the legacy fallback: flat `thinking` as one leading thinking segment, `text` as one answer segment. *Alternative — a parallel per-turn sidecar store: rejected; the message already persists `thinking`, and one optional field keeps one owner (the durable store) and zero migration.*

**D2 — One ordered accumulator in the engine, fed by both turn paths.** `NotchSessionEngine` grows `@Published liveSegments: [TurnSegment]` with a single append-or-coalesce rule: a token whose channel matches the last segment's kind appends to it; otherwise a new segment starts. The plain path feeds it directly from the `runtime.chat` token loop. The routed path generalizes its existing ordered `AsyncStream<String>` thinking consumer to `AsyncStream<(TokenChannel, String)>` and feeds **both** `AgentLoop.onThinking` and the newly wired `onResponseToken` through it, so cross-channel order is serialized exactly as emitted. The flat `@Published thinking` and `state = .conversing(partial:)` keep accumulating in parallel (existing seams/tests; the partial still drives pinned-scroll and the collapsed-while-streaming badge classification). On settle, `appendAssistantTurn` persists `segments = liveSegments` (coalesced) alongside `text`/`thinking` and clears the accumulator. *Alternative — deriving order in the view from two flat strings: impossible; interleaving information is lost at accumulation time.*

**D3 — The routed answer streams by wiring the sink that already exists.** `runRoutedTurn` passes `onResponseToken` into `AgentLoop` (today omitted → answer invisible until settle). No `AgentLoop` change: `answer(...)` already emits per-token callbacks for both channels.

**D4 — Transcript renders per-message segments; the live turn is a synthetic timeline entry.** `NotchConversationView` drops the bottom `thinkingSection` and the `.conversing(partial)` state bubble; instead the thread renders each assistant message's segments in order (answer segments as today's `BidiText` bubbles; thinking segments as muted, per-block collapsibles), and while a turn is in flight it renders the same segment view over `engine.liveSegments`. A **live** thinking segment streams expanded (you watch it think); a **settled** thinking segment collapses to a compact "Thinking" row, expandable per block. Auto-scroll pins on `liveSegments` mutations (superset of the old partial/thinking triggers). No new repeating animation (idle-CPU-spin rule) — streaming text itself is the motion.

**D5 — Settings zone is a third panel mode, not a second panel.** `NotchHomeZoneViewModel.Mode` grows `.settings`; the gear is a small icon button stacked **above the "+ New chat" card** in the rail's leading column. Clicking it mode-switches the same panel with the same border-stretch resize used by `expandSession` (a `NotchHomeZoneLayout` settings solve, compact fixed size); a back affordance (and clicking the gear again) returns to rail mode. The panel **never becomes key in settings mode** (slider + buttons are mouse-only, honoring the non-activating contract; only the composer ever takes key). **Grace-dismiss applies in settings mode as in rail mode** — it is a transient tweak surface, and only an expanded *conversation* pins the panel open; a grace-dismissed settings zone reopens as the rail. Feature-off/Space-switch teardown stays synchronous. *Alternative — hosting settings inside the expanded conversation chrome: rejected; the ask is a rail-level surface shaping future conversations, not a per-session control.*

**D6 — One slider, four ordered stops, one persisted level.** A Core enum `NotchTuning: String, CaseIterable — quick, balanced, deep, max` with derived semantics: `reasoning` (false for `quick`, true otherwise) and `contextTokens(modelMax:)` (quick/balanced → 8_192, deep → 32_768, max → modelMax — reusing `AgentContextPreset.tokens(modelMax:custom:)` resolution values). Persisted as one `AppSettings` key (`notchTuning`, default `.balanced`, matching today's effective defaults: reasoning on, 8192). The slider is a 0…3 discrete `Slider` mapped over `CaseIterable`, captioned with the stop's title plus "thinking on/off · N tokens". *Alternative — writing the global `aiReasoningEnabled`/`agentContextPreset`: rejected; the user asked for tuning “specifically this AI interface,” and the globals also steer the launcher band and every other agent surface.*

**D7 — Born-with tuning rides the conversation.** `AgentConversation` grows decode-safe optionals `reasoningOverride: Bool?` and `contextTokens: Int?`. `startNew()` snapshots the injected `tuningDefault: () -> (reasoning: Bool, contextTokens: Int)` (a closure reading `settings.notchTuning` + the model max at snapshot time, mirroring the existing `reasoningDefault` idiom) and stamps both onto the newborn conversation; `bind()` prefers the stored values and falls back to the legacy behavior (`reasoningDefault()`, injected budget) when absent — so pre-change sessions behave exactly as before. The compactor's budget becomes per-session: stored `contextTokens` → `DefaultContextBudget(maxContextTokens:)`, else the injected provider. `makeNotchSessionEngine` finally wires real numbers (clamped to the model max via the `AgentContextBudgetProvider` idiom). *Alternative — snapshot-only in the engine (the current reasoning behavior, re-read on every re-bind): rejected; “applied to following new conversations” means an existing session must keep the tuning it was born under, which requires persisting it.*

## Risks / Trade-offs

- **[Store growth: segments duplicate `text`/`thinking` per assistant message]** → Bounded by the conversation itself (already compacted against the budget); segments are plain text, display-only, and per-message — no unbounded stream retained.
- **[Per-token `@Published` churn on a SwiftUI list]** → The coalesce rule mutates only the **last** segment's string per token (the array's identity list changes only at channel flips), the same publish cadence the flat `thinking`/`partial` already sustain today.
- **[A live thinking block could tempt a shimmer/pulse]** → None added; the idle-CPU-spin rule stands (any future liveness cue must be occlusion-gated).
- **[Settings mode on a non-activating panel]** → Slider/buttons are mouse-driven (no key status needed); the key-flip stays composer-only, so focus behavior is unchanged.
- **[Legacy sessions with no stored tuning]** → Explicit fallback tier in `bind()` keeps their exact pre-change behavior; only newborn conversations carry tuning.
- **[Old builds reading new rows]** → Synthesized Codable decoding ignores unknown keys; `text`/`thinking` are still written, so a rollback renders what it always rendered.

## Migration Plan

No migration. All persisted growth is optional fields on already-stored types (the `dimPercent` precedent); existing rows decode unchanged, and the new fields decode as `nil` → legacy rendering/behavior. Rollback is safe (new keys ignored, legacy fields still authoritative for old code).

## Open Questions

None blocking. Follow-up candidate: interleave tool steps as a third segment kind so the timeline shows think → tool → answer end-to-end.
