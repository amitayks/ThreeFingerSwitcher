## Context

This is **Wave 1** of the V2 agent decomposition (`docs/ai-agent-v2-blueprint.md`) — the *type home*. It evolves the runtime + executor from a stateless single-prompt fire into a multi-turn **session**, and owns the canonical conversation types every other slice consumes. It must land before `ai-tool-routing`, `ai-conversational-canvas`, `ai-parked-sessions`, `ai-agent-memory`, and `ai-background-autonomy`, which all import its types verbatim.

Ground truth in the existing code (read before judging this design):

- **`AI/LLMRuntime.swift`** — `LLMRuntime` protocol (`generate`/`structured`/`capabilities`), `LLMRequest(prompt:image:parameters:reasoning:)`, `GenerationParameters`, `Token`/`TokenChannel(.response/.thinking)`, `StructuredSchema`/`StructuredOutcome`, the `RuntimeError` taxonomy + `LocalizedError`. **The `.thinking`/`.response` channel split already exists** — V2 reuses it; this slice adds no third channel.
- **`AI/AICommandExecutor.swift`** — `@MainActor ObservableObject` with an `enum State` (`.idle`/`.loadingModel`/`.noInput`/`.streaming(partial:)`/`.ready(result:)`/`.reviewingAction(TaskReview)`/`.declined(reason:)`/`.failed(message:)`/`.unavailable`/`.committed`), a `@Published thinking: String`, `canvasAtTop`, a per-fire `generationTask`, and `run(_:)` which streams tokens splitting `.thinking`→`thinking` and `.response`→`accumulated`→`.streaming`/`.ready`.
- **`AI/StubLLMRuntime.swift`** — the deterministic scriptable runtime: `scriptedTokens`/`scriptedThinking`, `interTokenDelayNanos`, `StructuredScript`, cancellation observation. Today it scripts ONE generation; this slice makes it script a **sequence** of generations (one per turn).
- **`AI/PromptTemplate.swift`** — `FireContext` + `PromptTemplate.resolve(...)` (`{input}`/`{date}`/`{app}`/`{url}`/`{lang}`). Reused to build turn-1 seed text.
- **`AI/AIError.swift`** — the single `AIError.message(for:) -> AIPresentedError` translator; every `.failed` headline routes through it.
- **`openspec/specs/on-device-ai-runtime/spec.md`** — the existing capability spec this slice delta-modifies.

The blueprint pins the exact shapes (§3.1, §3.2). This design implements them and the compaction logic; it does NOT redefine `ToolRoute`/`ToolStepResult` (owned by `ai-tool-routing`) — `AgentMessage` references them as the blueprint sketches, so the field types are declared here in their final form (this slice owns `AgentMessage`) but the `ToolRoute`/`ToolStepResult`/`ToolDescriptor` *definitions* are imported from the tool-routing slice. See D9 for the ordering resolution.

## Goals / Non-Goals

**Goals:**
- Own the canonical `AgentRole`/`AgentMessage`/`AgentSessionID`/`AgentConversation`/`AgentTurn` (blueprint §3.1), MLX-free Core, `Codable`, `Equatable`, `Sendable`.
- Add `LLMChatRequest` + a default-implemented `LLMRuntime.chat(_:)` (blueprint §3.2) — additive; existing conformers keep compiling via a messages→prompt flatten.
- Evolve `AICommandExecutor` into a session: hold history, append user + assistant turns, exclude `.thinking` from re-fed history, add multi-turn `State` cases without breaking the one-shot cases.
- Stream `.thinking`/`.response` per turn; store thinking on the message for display, response in history.
- Compaction: a pure windowing/estimate decision + a summarization model call producing `compactedSummary`, triggered by a budget read through an injected `ContextBudgetProviding`.
- Per-turn cancellation + per-turn `.failed` via `RuntimeError`/`AIError`.
- A multi-turn-scriptable `StubLLMRuntime` so `swift test` drives full deterministic conversations.

**Non-Goals:**
- The tool-route loop, `ToolRoute`/`ToolDescriptor`/`ToolStepResult`/`ToolRegistry` — `ai-tool-routing` owns these. This slice only references them as `AgentMessage` fields.
- The conversational canvas UX, the gesture compass, float-up, the overscroll-park trigger — `ai-conversational-canvas`.
- Durable on-disk conversation storage and the parked-session lifecycle — `ai-parked-sessions` owns the store; this slice owns the `Codable` type only.
- The `agentContextTokens` user slider + persisted key, `ModelDescriptor.maxContextTokens` plumbing, KV-quant, and the batched `chat` override — `ai-batched-runtime-and-context`. This slice reads the budget through an injected provider (C3).
- The real Gemma chat-template (`enable_thinking`, Gemma turn markers) — GemmaRuntime slice; this slice ships only the Core flatten-default + the Stub.
- A new `<Slice>Error` — turn failures fit `RuntimeError`; do not add a taxonomy.

## Decisions

### D1. The canonical conversation types (blueprint §3.1, verbatim shapes)

In `AI/Agent/AgentConversation.swift` (Core, MLX-free):

```
public enum AgentRole: String, Codable, Sendable { case user, assistant, system, tool }

public struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var role: AgentRole
    public var text: String              // committed user/response text — NEVER thinking
    public var thinking: String?         // reasoning, retained for DISPLAY only; never re-fed as ground truth
    public var image: Data?              // optional per-turn image (PNG); mirrors LLMRequest.image
    public var toolCalls: [ToolRoute]?   // assistant turn that routed to tools (type from ai-tool-routing)
    public var toolResult: ToolStepResult? // role == .tool: the executed step's outcome (ai-tool-routing)
    public var createdAt: Date
}

public struct AgentSessionID: Hashable, Codable, Sendable { public let raw: UUID }

public struct AgentConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentSessionID
    public var title: String
    public var messages: [AgentMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var compactedSummary: String?  // compaction output: prefix summary replacing dropped turns
    public var skillID: String?           // the active skill driving this session, if any
}

public struct AgentTurn: Sendable {
    public var messages: [AgentMessage]   // the windowed/compacted message list for THIS generation
    public var image: Data?               // convenience: latest turn's image
    public var reasoning: Bool
    public var parameters: GenerationParameters
}
```

- `text` is the contract for **what is re-fed**; `thinking` is the contract for **what is shown but never re-fed** — this is how "`.thinking` excluded from history" is enforced *by the type*, not by a runtime convention. Assembling an `LLMChatRequest` reads `message.text` only.
- `AgentSessionID` is the identity threaded through every slice, **stable across park/restore** (the parked slice persists the conversation under this id; the batched runtime keys streams by it).
- `AgentTurn` is the post-compaction unit handed to the runtime; it is the in-memory product of "windowed/compacted `messages` + the latest image + per-turn reasoning + parameters." It is **not** `Codable` (it's transient) — only `AgentConversation` persists.

### D2. `LLMChatRequest` + `chat()` — additive, default-flattened (blueprint §3.2; integration fix on existing seam)

In `AI/LLMRuntime.swift`, alongside the unchanged `LLMRequest`:

```
public struct LLMChatRequest: Sendable {
    public var messages: [AgentMessage]
    public var image: Data?
    public var parameters: GenerationParameters
    public var reasoning: Bool
    public var tools: [ToolDescriptor]?   // route-mode advertisement (ai-tool-routing); nil = plain chat
}

extension LLMRuntime {
    public func chat(_ request: LLMChatRequest) -> AsyncThrowingStream<Token, Error> {
        // DEFAULT: flatten messages → one prompt via ChatTemplate, then call generate(_:).
        let prompt = ChatTemplate.flatten(request.messages)
        return generate(LLMRequest(prompt: prompt, image: request.image,
                                   parameters: request.parameters, reasoning: request.reasoning))
    }
}
```

- **Additive**: `chat` is a protocol extension with a default body, so `StubLLMRuntime`, `DevAIRuntime`, and the existing Gemma conformer compile unchanged and immediately work multi-turn (via flatten). The batched MLX conformer overrides `chat` for true KV-reuse later — this slice does not write that override.
- `tools` is declared so the type is final (consumers don't have to widen it later), but this slice ignores it — only `ai-tool-routing` populates/reads it. `ToolDescriptor` is imported from that slice; see D9.
- The default `chat` honors `reasoning` and `image` by passing them straight through to `generate(_:)`, so the channel split and vision path are inherited for free.

### D3. `ChatTemplate.flatten` — the Core, model-agnostic assembler

In `AI/Agent/ChatTemplate.swift` (Core). The default `chat` impl needs *a* prompt from a message list; the real Gemma chat-template (with `<start_of_turn>` markers + `enable_thinking`) is a GemmaRuntime concern. So:

- `ChatTemplate.flatten(_ messages: [AgentMessage]) -> String` produces a plain, deterministic, role-labeled transcript (e.g. `System: …\n\nUser: …\n\nAssistant: …\n\nUser: …\n\nAssistant:`), reading **only `message.text`** (never `thinking`). A `.tool` message renders its `toolResult?.summary` as a `Tool:` line. The trailing `Assistant:` cue invites the next turn.
- This is enough for the Stub and the flatten-default to drive multi-turn deterministically and for tests to assert assembly. The **real** Gemma markers + `enable_thinking` flag are **flagged for the GemmaRuntime slice** (a `// FLAGGED: GemmaRuntime` comment + a spec scenario), where the batched conformer's `chat` override builds Gemma's native chat template instead of calling `flatten`.
- `flatten` is pure/`nonisolated`/static, unit-tested for role ordering, thinking-exclusion, tool-line rendering, and the trailing cue.

### D4. `AICommandExecutor` becomes a SESSION — additive `State` cases

Today the executor is one-shot. The evolution keeps every existing case and path working (the preset-command fire is unchanged) and **adds** session state:

- A new stored `private(set) var conversation: AgentConversation?` — the in-memory thread for the active session. `nil` until the first turn opens it. (Durable persistence is `ai-parked-sessions`; here it lives for the session's life in memory.)
- New additive `State` cases (the canvas slice will render these; they are observable here):
  - `.conversing(partial: String)` — an assistant turn is streaming *within an open thread* (distinct from the one-shot `.streaming`, which the preset path keeps using so its commit semantics are untouched). `partial` is the response-channel accumulation for the in-flight turn.
  - `.awaitingTurn` — the thread is open and idle, waiting for the next user turn (Enter = send, from the canvas).
  - The existing `.failed(message:)` carries per-turn failures.
  - `.committed`/`.ready` stay one-shot only. NOTE: `.awaitingApproval`/`.parked` are **owned by `ai-conversational-canvas`/`ai-tool-routing`** (blueprint §5.1) — this slice does not add them; it adds only the runtime-level conversing/awaiting states, leaving room for those slices to add theirs additively.
- `State` equality is extended for the new cases (mirroring the existing hand-written `==`).
- **Seed → turn 1.** A new `startConversation(seedText:image:parameters:reasoning:)` (or the existing `fire(_:)` evolves to call it for an agent-mode command) creates the `AgentConversation` with `messages = [AgentMessage(role:.user, text: seedText, image: image, createdAt: now)]`. The seed text comes from the SAME acquisition + `PromptTemplate.resolve` the one-shot path uses today — the seed is just turn 1.
- **A turn loop** `runTurn()` (private, `async`):
  1. Append the pending user `AgentMessage` (if not already the last message).
  2. Assemble the `LLMChatRequest` via `assembleRequest()` (D5) — applying compaction first (D6).
  3. `state = .conversing(partial: "")`; reset the live `thinking` for this turn (so a new turn never shows the prior turn's reasoning).
  4. Stream `runtime.chat(request)`: `.thinking` tokens → live `thinking` (display); `.response` tokens → `accumulated` → `.conversing(partial:)`.
  5. On completion: append `AgentMessage(role:.assistant, text: accumulated, thinking: thinking.isEmpty ? nil : thinking, createdAt: now)`. **`text` = response only; `thinking` is stored for display but never re-fed.** `state = .awaitingTurn`.
  6. On `RuntimeError.cancelled` / `CancellationError`: return (a discard is not a failure; the partial assistant turn is NOT appended). On any other error: `state = .failed(message: AIError.message(for:).headline)`.

### D5. `assembleRequest()` — conversation → `LLMChatRequest` (channel-honest)

- Builds the message list fed to the runtime from `conversation.messages`, **prefixing the `compactedSummary`** as a synthetic `AgentMessage(role:.system, text: compactedSummary)` when present (so the model still "remembers" the dropped turns).
- **Re-feeds `message.text` only** — `thinking` is structurally excluded (it lives in a separate field that assembly never reads). This is the core "thinking never bloats context" guarantee.
- `image` = the latest user turn's image (convenience field on `AgentTurn`/`LLMChatRequest`); reasoning = the resolved per-command/global reasoning (reusing today's `command.resolvedReasoning(globalDefault:)` plumbing); parameters = `GenerationParameters` as today.

### D6. Compaction — pure windowing decision + a summarization model call (this slice OWNS it)

The hard part. Split into a pure decision and an impure pass:

- **`ContextBudget.swift` (Core):**
  - `protocol ContextBudgetProviding: Sendable { var maxContextTokens: Int { get } }` — the **injected** budget seam (integration fix **C3**). The executor depends on this protocol, NEVER on the concrete `agentContextTokens` slider. The app wires a real provider (backed by `ModelDescriptor.maxContextTokens` ∩ the user's `agentContextTokens`, both owned by `ai-batched-runtime-and-context`); tests pass a fixed-budget stub. This is why this slice can land before the batched-runtime slice.
  - `TokenEstimator` — a pure, deterministic estimate of an `[AgentMessage]`'s token cost (a character/word-ratio heuristic; estimates `text` only, never `thinking`, since thinking is not re-fed). Honest about being an estimate, not a real tokenizer — the budget keeps a safety margin (e.g. compact at 80% of `maxContextTokens`).
- **`ConversationCompactor.swift` (Core):**
  - `func needsCompaction(_ conversation: AgentConversation, budget: ContextBudgetProviding) -> Bool` — pure: estimate the assembled messages (incl. any existing `compactedSummary` prefix); true when the estimate crosses the compaction threshold (margin-adjusted budget).
  - `func plan(_ conversation: AgentConversation, budget: ContextBudgetProviding) -> CompactionPlan` — pure: decides which prefix of `messages` to collapse (always keep the most recent `keepRecentTurns` turns verbatim; collapse everything older, including any prior summary, into the new summary's *input*). Returns the to-summarize slice + the to-keep tail. Deterministic and unit-testable with a fixed-budget stub.
  - `func summarize(_ plan: CompactionPlan, runtime: LLMRuntime) async throws -> String` — the impure pass: a single `runtime.generate(LLMRequest(prompt: summarizationPrompt))` call (reasoning OFF) that condenses the to-summarize slice into a compact factual summary string. Maps any error through `RuntimeError`/`AIError`.
  - Applying the plan: `conversation.compactedSummary = summary`; `conversation.messages = plan.keptTail`. The summary then enters the next `assembleRequest()` as the `system` prefix (D5).
- **Trigger timing:** compaction runs inside `runTurn` *before* assembly, only when `needsCompaction` is true. The compaction summarization call is itself cancellable (it's part of the turn's task). A failed summarization is a turn `.failed` (never silently drops history → never a false continuation).
- **Coordinate the budget with the batched-runtime/context slice (C3):** the provider protocol is the contract; the concrete `maxContextTokens` field on `ModelDescriptor` and the `agentContextTokens` user slider are owned there. This slice ships the protocol + a test stub + a default provider (a constant fallback) so it builds standalone.

### D7. Channels across turns (reuse the existing split, repeat per turn)

- Per turn, the streaming loop is the same channel split as today's `run(_:)`: `.thinking` → live `thinking` (the canvas's collapsible section, updated live), `.response` → `accumulated`. The ONLY change is that this now runs per turn and the results are persisted onto an `AgentMessage` (D4.5): `text = response`, `thinking = the accumulated reasoning (display only)`.
- `thinking` (the `@Published` live string) is reset at the START of each turn so a new turn never shows the prior turn's reasoning live; the prior turn's reasoning remains available on its `AgentMessage.thinking` for the transcript.
- No third channel is added (blueprint: do not add one without cross-slice sign-off).

### D8. `StubLLMRuntime` multi-turn scripting (so `swift test` drives full conversations)

- Add a `scriptedTurns: [TurnScript]` queue where `TurnScript { tokens: [String], thinking: [String] }`. Each `chat`/`generate` call dequeues the next `TurnScript` (FIFO); when the queue is exhausted it falls back to today's `scriptedTokens` behavior (so existing single-generation tests are byte-identical). A dedicated `scriptedSummary: String?` (or a reserved turn) lets a test script the compaction summarization call's output.
- The default `chat` impl flattens then calls `generate`, so the Stub's `generate` is the single place that consumes a `TurnScript` — no separate `chat` override needed in the Stub (it inherits the default). The Stub keeps honoring per-call cancellation (per-turn discard) and can be scripted to throw a `RuntimeError` on a chosen turn (per-turn `.failed`).
- This lets a test assert: turn-1 response, turn-2 sees turn-1 in the assembled prompt (via a flatten assertion), `.thinking` never appears in the re-fed prompt, a compaction summary replaces old turns, a mid-turn cancel leaves no assistant message, a scripted turn error → `.failed`.

### D9. Type-ownership ordering: `AgentMessage` references tool types owned by a *later* slice

`AgentMessage.toolCalls: [ToolRoute]?` and `.toolResult: ToolStepResult?` reference types `ai-tool-routing` owns (Wave 2, *after* this slice). Resolution (no DAG back-edge, no forked type):

- This slice OWNS `AgentMessage` and declares those two fields in their final shape. `ai-tool-routing` lands `ToolRoute`/`ToolStepResult`/`ToolDescriptor`/`WritePolicyTier` as Core types. Both are in the same `ThreeFingerSwitcherCore` module, so `AgentMessage` can reference them without an import cycle once both exist.
- **Sequencing reality:** to let this slice's *code* compile standalone before tool-routing lands, the implementing PR for THIS slice introduces minimal placeholder `ToolRoute`/`ToolStepResult`/`ToolStepStatus`/`ToolDescriptor`/`WritePolicyTier` value types EXACTLY as blueprint §3.3/§3.7 sketch them, in a Core file, and `ai-tool-routing` then *takes ownership* (moves the loop/registry logic onto them) without changing the shapes. The blueprint pins the shapes precisely so this hand-off is mechanical. The tasks list this explicitly (task 7) and the spec delta notes the cross-slice ownership.
- This is the only place this slice touches another slice's types; everything else (`LLMChatRequest.tools`) is just declared-and-ignored here.

### D10. Errors — reuse the taxonomy; no new `<Slice>Error`

- Every turn failure (generation error, summarization error, decode) maps through the existing `RuntimeError` taxonomy and surfaces via `AIError.message(for:).headline` into `.failed(message:)`. Cancellation is benign (a discard) — not a failure. A summarization that fails is a turn `.failed`, never a silent history drop. No new error type is justified (blueprint: add `<Slice>Error` only where `RuntimeError`/`TaskError` cannot carry the case — they can here).

### D11. `@MainActor` + concurrency

- `AICommandExecutor` stays `@MainActor ObservableObject` (its convention). The turn loop is a retained `Task` (like today's `generationTask`) so a discard cancels it. Per-turn streaming mutates `@Published state`/`thinking` on the main actor as today.
- The Core value types (`AgentMessage` et al.) and the pure compaction logic are `Sendable`/`nonisolated`, so they cross the actor boundary cleanly and are testable off the main actor.

## File-level touch list (target + verification)

| File | Target | Change | Verified by |
|---|---|---|---|
| `AI/Agent/AgentConversation.swift` (new) | Core | `AgentRole`/`AgentMessage`/`AgentSessionID`/`AgentConversation`/`AgentTurn` (D1) | `swift test` (Codable round-trip, thinking-exclusion invariant, equality) |
| `AI/Agent/ChatTemplate.swift` (new) | Core | `ChatTemplate.flatten` (D3); real Gemma markers FLAGGED for GemmaRuntime | `swift test` (role order, thinking excluded, tool line, trailing cue) |
| `AI/Agent/ContextBudget.swift` (new) | Core | `ContextBudgetProviding`, `TokenEstimator`, default constant provider (D6, C3) | `swift test` (estimate monotonicity, margin, injected stub) |
| `AI/Agent/ConversationCompactor.swift` (new) | Core | `needsCompaction`/`plan`/`summarize` + apply (D6) | `swift test` (plan keeps recent N, collapses prefix incl. prior summary; summarize via Stub; failure → throws) |
| `AI/Agent/ToolPlaceholders.swift` (new, temporary) | Core | placeholder `ToolRoute`/`ToolStepResult`/`ToolStepStatus`/`ToolDescriptor`/`WritePolicyTier` (D9) — handed to `ai-tool-routing` | `swift build` (compiles); `ai-tool-routing` takes ownership later |
| `AI/LLMRuntime.swift` | Core | add `LLMChatRequest` + `LLMRuntime.chat(_:)` default impl (D2) | `swift test` (default flatten path), `xcodebuild` (Gemma conformer still compiles) |
| `AI/AICommandExecutor.swift` | Core | session history, `.conversing`/`.awaitingTurn` States + equality, `startConversation`/`runTurn`/`continueConversation`/`assembleRequest` (D4/D5/D7) | `swift test` (full scripted conversation, per-turn cancel, per-turn fail, compaction trigger) |
| `AI/StubLLMRuntime.swift` | Core | `scriptedTurns` queue + scripted summary + per-turn throw (D8) | `swift test` |
| `Tests/ThreeFingerSwitcherTests/AgentConversationTests.swift` (new) | Test | type + assembly + thinking-exclusion | `swift test` |
| `Tests/ThreeFingerSwitcherTests/ConversationCompactionTests.swift` (new) | Test | windowing/plan/summarize | `swift test` |
| `Tests/ThreeFingerSwitcherTests/ConversationSessionTests.swift` (new) | Test | executor multi-turn session machine | `swift test` |
| `AI/GemmaRuntime/*` (the real `chat` override + Gemma chat-template) | GemmaRuntime | **FLAGGED, not in this slice** — owned by `ai-batched-runtime-and-context` | `xcodebuild` compile-only when it lands |

**Verification split:** essentially all of this slice is MLX-free Core verified by `swift build` + `swift test`. The only `xcodebuild` concern is confirming the additive `chat` default + `LLMChatRequest` don't break the GemmaRuntime conformer's compile (the agent runs `xcodebuild` compile-verify only; never builds/signs/installs the `.app`). The real Gemma chat-template override is explicitly deferred. To compile-check this slice in isolation from sibling uncommitted files, use a throwaway `git worktree` + `swift build`.

## Edge cases

- **First turn with no input.** A seed with empty/whitespace text AND no image → the existing `.noInput` path (no conversation opened, no model call) — preserved from today.
- **Mid-turn discard.** Cancelling during streaming: the partial assistant turn is NOT appended (no half-message in history); the conversation stays at the prior `.awaitingTurn`/closed state; not a failure.
- **Compaction mid-turn fails.** The summarization model call throws → turn `.failed` with a clean headline; history is NOT dropped (the plan is applied only on a successful summary), so the next retry sees the full thread.
- **Thinking leak.** A bug that re-fed `thinking` would bloat the window and violate the contract — assembly reads `text` only, and the type stores thinking in a separate field; a unit test asserts the assembled prompt never contains a turn's `thinking` string.
- **Budget smaller than the kept tail.** If even `keepRecentTurns` exceeds the budget, compaction collapses to the minimum viable (most-recent turn + summary); the estimator's margin means we compact early rather than overflow. (M5/48GB: the model max is large; this is a guard, not a hot path.)
- **Empty conversation assembly.** Assembling with zero messages is a no-op guarded before any model call.
- **Reasoning off.** No `.thinking` tokens arrive; `AgentMessage.thinking` stays `nil`; identical to today's response-only stream.
- **Image only on turn 1.** A vision seed carries the image on turn 1's user message; later turns have no image (the convenience `AgentTurn.image` is the latest turn's image, nil after turn 1) — matches today's single-image fire.
- **Stub turn queue exhausted.** Falls back to legacy `scriptedTokens` so existing tests are unaffected.

## Rejected alternatives

- **Replace `LLMRequest`/`generate` with messages everywhere.** Rejected — breaks every existing conformer and the one-shot preset path, violates "additive, never breaking" (blueprint §0). The default-flattened `chat` extension gives multi-turn for free while leaving `generate` untouched.
- **A new `ConversationError` taxonomy.** Rejected — `RuntimeError` already carries cancellation/decode/unavailable/couldNotProduceValid; turn failures fit it. The blueprint forbids a new `<Slice>Error` where the existing taxonomy suffices.
- **Store `thinking` in `text` and strip at assembly.** Rejected — fragile (a strip bug leaks reasoning into context). Storing thinking in a separate field makes exclusion structural, not procedural.
- **Read the `agentContextTokens` slider directly for the budget.** Rejected — creates a hard dependency on `ai-batched-runtime-and-context` landing first (DAG back-edge). The injected `ContextBudgetProviding` (C3) breaks the cycle; the concrete slider is wired by the app later.
- **A separate `ConversationStore` here.** Rejected — `ai-parked-sessions` owns durable storage; duplicating it would fork the store. This slice owns only the in-memory `AgentConversation` + its `Codable` conformance.
- **Summarize via `structured()`.** Rejected for v1 — a free-text summary fed back as a `system` prefix is simpler and robust; structured summarization adds schema brittleness for no gain. (`structured()` stays the router's job in tool-routing.)
- **A third token channel for tool/summary output.** Rejected — blueprint pins `.thinking`/`.response` and bars a third channel without sign-off; the summarization call uses plain `.response`.
