## Context

The agentic task layer already exists and is the thing V2 inverts control over. Read these before the design:

- **`AI/LLMRuntime.swift`** — `structured(_:schema:as:) -> StructuredOutcome<T>` is the seam this slice repurposes as the router. Its contract is exactly what we need: VALIDATE against a `StructuredSchema`, REPAIR/RETRY within a bounded loop, decode into `T`, and allow a first-class `.declined`. It throws `RuntimeError.couldNotProduceValid(attempts:)` only when the bounded loop is exhausted. `Token`/`TokenChannel.thinking` already splits reasoning from the committed answer. `RuntimeError` is the shared, `Equatable`, `LocalizedError` taxonomy.
- **`AI/Tasks/TaskDispatching.swift` + `TaskDispatcher.swift`** — `prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource, reasoning:) async -> TaskReview` and `execute(_ review:) async throws`. `prepare` runs `runtime.structured(...)` against the **kind's own** `ParsedActions` schema and maps a typed/affordance decline → `.declined`, exhausted validation → `.unavailable`, success → `.action(title:fields:payload:)`. `execute` fires the side effect for a confirmed `.action` ONLY. **Critical:** `prepare` takes a `resolvedPrompt: String`, NOT an arbitrary args object — the kind selects the schema; the prompt is the model's input. This is the bridge point (Decision 4).
- **`AI/Tasks/TaskReview.swift` / `ParsedActions.swift` / `TaskSinks.swift`** — `TaskReview` (`.action`/`.declined`/`.unavailable`), `PreparedAction` (the opaque validated payload), `ReviewField`, `TaskSource`, `TaskError` (`LocalizedError`, the side-effect taxonomy), and the small injectable sinks. All MLX-free, all unit-tested headless.
- **`AI/AICommandExecutor.swift`** — the existing fire→stream→commit state machine. NOT modified here (the conversational extension is `ai-conversational-canvas`). This slice's loop is observable state the canvas binds to.
- **`AI/AICommand.swift`** — `TaskKind` (calendar/reminder/contact/saveToProject/openToolWithPayload/sendTo) and `Destination`.

The shared blueprint (`docs/ai-agent-v2-blueprint.md` §3.3) pins the route contract; this slice OWNS those types. Integration fix **C1** puts the bare `WritePolicyTier` enum HERE (with `ToolDescriptor`), so every descriptor carries its tier with no DAG back-edge to `ai-background-autonomy`.

**Dependency note (honest):** the sibling change dirs `openspec/changes/ai-conversation-runtime/` and `.../on-device-ai-runtime/` are NOT yet on disk in this repo. This slice consumes `AgentMessage`/`AgentConversation`/`AgentSessionID`/`LLMChatRequest`/`chat()` from the blueprint's §3.1/§3.2 **sketches**. Where a type I consume is not yet committed, the design declares a narrow Core protocol seam I own (`ConversationContext`, `ChatStreaming`) so this slice compiles and `swift test`-passes in isolation, and binds to the real types when the owner slice lands. See Open Questions.

## Goals / Non-Goals

**Goals:**
- Invert who-drives: the **model** picks the tool via a `structured()` route turn against a fixed `RouteSchema` — the reliability mechanism is `structured()`'s repair/retry/decline, NOT Gemma native function-call tokens.
- "No tool, just talk" (`tool == ""` / `.declined`) is **first-class**, the common case, never a failure.
- Reuse `TaskReview`/`PreparedAction`/`ParsedActions`/`TaskSinks`/`TaskDispatcher` **wholesale**; the model only chooses the `TaskKind` (+ its stored config) the user used to choose.
- A **bounded** agent loop: hard step cap, live plan via `.thinking`, per-step approval (DOWN=approve / RIGHT=skip), and no-progress/loop-guard termination.
- **Candidate retrieval:** ~3–5 candidate tools per route turn, never the full registry; the shape is shared with skills + memory (`DocIndex`, blueprint §3.4).
- Entire slice MLX-free Core, verified by `swift test` with scripted `StubLLMRuntime` structured outcomes.

**Non-Goals:**
- Conversation/message types + compaction (`ai-conversation-runtime` OWNS §3.1; consumed here).
- Canvas state cases + gesture interpretation + rendering (`ai-conversational-canvas` OWNS; this slice exposes observable loop state + the approval contract, it does not draw).
- The real batched MLX runtime (`ai-batched-runtime-and-context`); this loop drives an injected `LLMRuntime` and is agnostic to which conformer it is.
- The `DocIndex` retriever implementation (`ai-skills-as-files` OWNS; consumed here behind the candidate seam).
- The whitelist, the append-only audit log, and `.needsYou` escalation (`ai-background-autonomy` OWNS; consumed via `WritePolicyResolving`, with a stand-alone default).
- `launch_claude` / `ClaudeHandoffConfig` (`ai-claude-handoff`); it arrives as one more `ToolContributor` with no loop change.
- Native Gemma tool-call token parsing — explicitly rejected (Decision 1, Rejected Alternatives).

## Decisions

### 1. The route turn IS a `structured()` call against a fixed `RouteSchema` (NOT native function-call tokens)
`RouteSchema` is a single `StructuredSchema` (a `static let`, mirroring `ParsedCalendarEvent.schema`) describing the decision shape:

```jsonc
{
  "type": "object",
  "required": ["tool"],
  "properties": {
    "tool": { "type": "string", "description": "the chosen tool name, or \"\" to answer directly" },
    "argumentsJSON": { "type": "string", "description": "JSON object of arguments for the chosen tool" },
    "rationale": { "type": "string", "description": "one short sentence: why this choice" }
  }
}
```

`ToolRouter.route(...)` builds a route prompt — the conversation tail + the **candidate** tool descriptors (`name`, `summary`, and each tool's `argsSchema.json`) + an instruction to choose one or answer directly — and calls `runtime.structured(LLMRequest(prompt:reasoning:), schema: RouteSchema, as: ToolRoute.self)`. Outcomes map:
- `.value(route)` with `route.tool == ""` → **plain answer** (the loop streams a text turn and stops).
- `.value(route)` with a non-empty `route.tool` that matches a candidate descriptor → a **routed call**.
- `.value(route)` with a `tool` that matches NO descriptor → treated as a plain answer (defensive; never dispatch an unknown tool). Logged.
- `.declined(reason)` → **plain answer** (the model judged no tool fits — exactly the first-class "just talk").
- `throws RuntimeError.couldNotProduceValid` → **plain answer** fallback (a malformed route is never a fabricated tool call; the spec's "do not depend on hard token-level caging" applies to the router itself).
- any other `throws` → mapped via `AIError.message(for:)` to a clean headline, surfaced as a `.failed` loop outcome (never silence).

This reuses the seam we already trust for structure and inherits its repair/retry/decline for free. **The router is the reliability mechanism; the model's raw tokens are never parsed for tool calls.**

### 2. Type contracts (blueprint §3.3, OWNED here) — bare `WritePolicyTier` lives here (C1)
```swift
public enum WritePolicyTier: String, Codable, Equatable, Sendable {
    case auto        // whitelisted/safe: runs without confirm, even when parked (still audited downstream)
    case confirm     // default: needs foreground approval (DOWN=approve / RIGHT=skip)
    case dangerous   // always escalates to foreground (needs-you), even if parked
}

public struct ToolDescriptor: Codable, Equatable, Sendable {
    public let name: String              // stable id, e.g. "add_to_calendar", "send_to", "memory.write"
    public let summary: String           // one line the router sees
    public let argsSchema: StructuredSchema
    public let writePolicy: WritePolicyTier
    public var keywords: [String]        // cheap retrieval ranking signal (Decision 6)
}

public struct ToolRoute: Codable, Equatable, Sendable {
    public let tool: String              // "" = plain text answer
    public let argumentsJSON: String     // JSON object string; "" when tool == ""
    public let rationale: String?
    public var isPlainAnswer: Bool { tool.isEmpty }
}

public struct ToolStepResult: Codable, Equatable, Sendable {
    public let tool: String
    public let status: ToolStepStatus
    public let summary: String           // short human outcome; fed back as a .tool message
}
public enum ToolStepStatus: Codable, Equatable, Sendable {
    case done
    case awaitingApproval
    case declined(reason: String)
    case failed(headline: String)        // AIPresentedError.headline ONLY; raw text → logs/details
}
```
`WritePolicyTier` is defined here so a descriptor is self-describing. `ai-background-autonomy` does NOT redefine it — it owns the user **whitelist**, effective-tier **resolution** (`descriptor.writePolicy ∩ whitelist`), the audit log, and escalation. `ai-agent-memory` and `ai-claude-handoff` CONSUME the enum off their descriptors.

### 3. `ToolRegistry` + `ToolContributor` — aggregation, no loop coupling
```swift
public protocol ToolContributor: Sendable {
    func descriptors() -> [ToolDescriptor]
    func canHandle(_ tool: String) -> Bool
    // Run a routed call; returns a ToolStepResult. May produce an awaitingApproval pause.
    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult
}

public struct ToolRegistry: Sendable {
    private let contributors: [ToolContributor]
    public func allDescriptors() -> [ToolDescriptor]
    public func descriptor(named: String) -> ToolDescriptor?
    public func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult
}
```
v1 ships ONE contributor: `TaskKindToolContributor` (Decision 4). Later waves register `MemoryToolContributor`, `SkillToolContributor`, `ClaudeHandoffContributor` — each just adds descriptors and a `run`; the loop is untouched. The registry is the blueprint's "aggregates TaskKind tasks + memory tools + skill invocation + launch_claude."

### 4. The bridge: a routed call → the EXISTING `TaskDispatcher.prepare`/`execute` (the load-bearing reuse)
`TaskDispatcher.prepare` takes a `resolvedPrompt: String` and selects the schema from the `TaskKind`. A `ToolRoute` carries `argumentsJSON`. The bridge in `TaskKindToolContributor`:
1. Map `ToolDescriptor.name` → a `TaskKind` (+ its stored config). The descriptor for a `saveToProject`/`openToolWithPayload`/`sendTo` tool **binds the config at registration** (project name / tool / destination come from the authored command or skill, never invented by the router — exactly the existing rule in `ParsedActions.swift`). So `name == "save_to_project:<project>"`-style descriptors resolve back to `TaskKind.saveToProject(project:)`.
2. Build the `resolvedPrompt` the dispatcher expects by **folding the route's `argumentsJSON` into the prompt** as a structured instruction block (e.g. "Use these arguments: {…}"). The dispatcher's own `structured()` parse then re-validates against the kind's `ParsedActions` schema — so the router's args are a *hint*, and the kind's schema remains the authority. This keeps `TaskDispatcher`/`ParsedActions`/`TaskSinks` **byte-unchanged**: the model "chose the menu item and pre-filled it"; the existing two-stage prepare still validates.
3. Call `dispatcher.prepare(kind, resolvedPrompt:, source:, reasoning:)` → `TaskReview`.
4. Map `TaskReview` → `ToolStepResult` + the approval decision (Decision 5).

This is why the slice says "reuse the task machinery WHOLESALE": the contributor is a thin adapter; no parse logic, no sink, no schema is duplicated.

### 5. Per-step gating: read-only auto-runs; side-effecting waits for DOWN=approve
A descriptor's `writePolicy` (intersected by an injected `WritePolicyResolving`) decides the gate:
- `.auto` → run immediately: `prepare` → if `.action`, `execute` right away → `ToolStepResult(.done, summary)`.
- `.confirm` / `.dangerous` → `prepare` → if `.action`, **pause**: emit `ToolStepResult(.awaitingApproval, summary)` and surface the backing `TaskReview` as observable loop state. The loop suspends until the `ApprovalGate` resolves:
  - **approve (DOWN)** → `execute(review)` → `.done` (or `.failed` if the sink throws — never a false "Done", per the executor's existing honesty rule).
  - **skip (RIGHT)** → `ToolStepResult(.declined(reason: "skipped"))`, fed back so the model continues without that effect.
- `prepare` → `.declined` → `ToolStepResult(.declined(reason))` (no gate; nothing fires).
- `prepare` → `.unavailable(reason)` → `ToolStepResult(.failed(headline: reason))`.

```swift
public protocol WritePolicyResolving: Sendable {
    func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier
}
// Stand-alone default so this slice compiles + tests without ai-background-autonomy:
public struct DescriptorWritePolicy: WritePolicyResolving {
    public func effectiveTier(for d: ToolDescriptor) -> WritePolicyTier { d.writePolicy }
}
```
`ApprovalGate` is an async seam the canvas drives (DOWN/RIGHT). In tests it is a scripted gate that approves/skips deterministically. The canvas (slice `ai-conversational-canvas`) binds the `.awaitingApproval` `TaskReview` to its action-review preview and resolves it with the canonical compass DOWN=approve / RIGHT=skip — identical mnemonic to commit/discard.

### 6. Candidate retrieval — never the full registry in front of the router
A `ToolCandidateSource` surfaces ~3–5 candidates per route turn:
```swift
public protocol ToolCandidateSource: Sendable {
    func candidates(for context: RouteContext, limit: Int) -> [ToolDescriptor]
}
```
v1 default `KeywordToolCandidateSource`: cheap lexical match of the latest user turn against each descriptor's `name`/`summary`/`keywords` (token overlap + substring), top-`limit` (default 5), always including any tool the active skill explicitly allows. The shape deliberately mirrors `DocIndex.retrieve(query:limit:) -> [IndexedDoc]` (blueprint §3.4) so when `ai-skills-as-files`/`ai-agent-memory` land, a `DocIndexToolCandidateSource` adapter ranks skill/memory tools through the SAME retriever — no second ranking path. **Retrieval is itself a routed tool step:** a `widen_candidates`/`retrieve` `ToolDescriptor` lets the model ask for more tools when the 5 candidates don't fit, re-entering the loop with a broader set (blueprint §3.4 "retrieval is itself a routed tool step").

### 7. The bounded loop (`AgentLoop`) — route → execute → continue, with a hard cap + loop-guard
Pure Core, owns no UI. `now`/randomness are not needed (the loop is deterministic given scripted outcomes). Shape:

```
loop step s from 0 ..< maxToolSteps:        // maxToolSteps default 8
  candidates = candidateSource.candidates(for: context, limit: 5)
  route = router.route(context, candidates)          // a structured() call (Decision 1)
  emit route.rationale into the .thinking channel    // live plan (Decision 8)
  if route.isPlainAnswer:
      stream a final text answer turn; END(.answered)
  guard let d = registry.descriptor(named: route.tool) else { stream answer; END(.answered) }
  // loop-guard / no-progress (Decision 9):
  if route == lastRoute { END(.stopped(.repeatedStep)) }
  result = registry.run(RoutedCall(descriptor: d, route: route, source:), gate: gate)
  append .tool AgentMessage(toolResult: result) to context
  emit result.summary into .thinking
  switch result.status:
     .failed(h):    END(.failed(headline: h))         // a side effect that didn't land
     .declined:     continue (the model sees it and may re-route)
     .done / .awaitingApproval→resolved: continue
  lastRoute = route
END(.capReached) when the for-range is exhausted → stream a best-effort final answer noting the cap.
```
Terminal outcomes are an observable `AgentLoopOutcome` enum (`.answered(text)`, `.stopped(reason)`, `.failed(headline)`, `.capReached`). A `.failed` always carries a clean `AIPresentedError.headline`. The loop NEVER ends silently and NEVER fires a side effect outside `registry.run` (which itself only fires through the gated `TaskDispatcher.execute`).

### 8. The live plan rides the existing `.thinking` channel — no third channel
Each step's `route.rationale` and each `ToolStepResult.summary` are emitted as `.thinking`-channel text (blueprint: "do NOT add a third channel without cross-slice sign-off"). The canvas already renders `.thinking` into its collapsible section; the running plan appears there for free. The committed answer is `.response`-channel only, exactly as today. The visible-plan UX contract with `ai-conversational-canvas`: the loop publishes an ordered `[ToolStepResult]` + the current `.awaitingApproval` review as observable state; the canvas draws the step list + the pending approval card and feeds the `ApprovalGate`.

### 9. No-progress / loop-guard (small-model spin defense)
Two cheap guards, both pure and unit-tested:
- **Repeated step:** if a `ToolRoute` is byte-identical to the immediately preceding executed route (same `tool` + `argumentsJSON`), END `.stopped(.repeatedStep)` — the model is spinning on the same call.
- **Declined-then-re-route ceiling:** if the model re-routes to the same tool after it just `.declined`/`.failed` for that tool more than once, END `.stopped(.noProgress)`. A `.declined` result is fed back so the model *can* pivot; refusing to pivot terminates.
- The **hard step cap** (`maxToolSteps`) is the backstop regardless of progress.
On any guard termination the loop streams a best-effort final answer summarizing what it did and why it stopped (never a bare halt).

### 10. Errors — one taxonomy, mapped at the boundary, observable + bounded
- Router/runtime failures map through `AIError.message(for:)` → `ToolStepResult(.failed(headline))` / `AgentLoopOutcome.failed(headline)`. `RuntimeError.cancelled` (a discard) is NOT a failure — it ends the loop quietly like the executor's existing cancel path.
- Task-side failures are already `TaskError` (`LocalizedError`) mapped in `TaskSinks`; `prepare`/`execute` surface clean reasons; the contributor passes the clean headline into `.failed`.
- **No new `<Slice>Error` is introduced** — `RuntimeError` + `TaskError` carry every failure this slice can produce (route-malformed → `couldNotProduceValid` → plain-answer fallback, not an error; unknown tool → defensive plain answer, logged). This honors "at most one `<Slice>Error`, only if `RuntimeError`/`TaskError` cannot carry it."
- No `NSAlert`. The slice produces only observable state + clean headlines; the canvas renders them bounded + non-blocking with a Retry/Skip affordance.

## Type & file touch list (all Core, MLX-free; verified by `swift test` unless noted)

| File (new unless noted) | Target | Contents | Verification |
|---|---|---|---|
| `AI/Agent/ToolContracts.swift` | Core | `WritePolicyTier`, `ToolDescriptor`, `ToolRoute`, `ToolStepResult`, `ToolStepStatus`, `RoutedCall`, `RouteContext` | `swift test` (Codable round-trip, Equatable) |
| `AI/Agent/RouteSchema.swift` | Core | `RouteSchema` (`static let` `StructuredSchema`) + route-prompt builder (candidates → prompt text) | `swift test` (prompt includes candidate names/schemas) |
| `AI/Agent/ToolRouter.swift` | Core | `ToolRouter.route(...)` over `runtime.structured(...)`; outcome→route mapping incl. decline/couldNotProduceValid fallbacks | `swift test` w/ scripted `StubLLMRuntime` |
| `AI/Agent/ToolRegistry.swift` | Core | `ToolContributor`, `ToolRegistry`, `ApprovalGate` (async approve/skip seam) | `swift test` (aggregation, dispatch, unknown-tool) |
| `AI/Agent/TaskKindToolContributor.swift` | Core | descriptors for the existing `TaskKind`s; the args→`resolvedPrompt` fold; `TaskReview`→`ToolStepResult` mapping; gate integration | `swift test` w/ fake `TaskDispatching` + scripted gate |
| `AI/Agent/WritePolicyResolving.swift` | Core | `WritePolicyResolving` seam + `DescriptorWritePolicy` default | `swift test` |
| `AI/Agent/ToolCandidateSource.swift` | Core | `ToolCandidateSource` + `KeywordToolCandidateSource` (+ the `widen_candidates`/`retrieve` descriptor) | `swift test` (top-N ranking, skill-allowed inclusion) |
| `AI/Agent/AgentLoop.swift` | Core | the bounded route→execute→continue loop; `AgentLoopOutcome`; step cap; loop-guard; `.thinking` plan emission | `swift test` (cap, loop-guard, plain-answer, approval pause, failed-step) |
| `AI/Agent/ConversationSeam.swift` | Core | narrow `ConversationContext`/`ChatStreaming` protocols I own UNTIL `ai-conversation-runtime` lands, then re-pointed at `AgentMessage`/`chat()` (Open Question Q1) | `swift test` |
| `Tests/.../ToolRouterTests.swift` etc. | Core (test) | scripted `StubLLMRuntime` structured outcomes; fake dispatcher/gate/candidate source | `swift test` |

No file in this slice links MLX. The real model that ultimately answers route turns is the batched conformer from `ai-batched-runtime-and-context` (xcodebuild compile-only there); here the loop drives an injected `LLMRuntime` and is verified entirely against `StubLLMRuntime`. **No `.app` build, no signing, no permission change — the user's stable-signed build is unaffected.**

## Edge cases

- **Route says a tool the candidate set didn't include** (model hallucinated a name): no descriptor → defensive plain answer, logged; never dispatched. The `widen_candidates` tool is the legitimate path to more tools.
- **Route returns `tool != ""` but empty/garbage `argumentsJSON`:** the fold passes whatever it has; the kind's own `structured()` parse in `prepare` either repairs it or returns `.unavailable` → `.failed` step → model sees it and can re-route. The router's bad args never reach a sink unvalidated.
- **`.awaitingApproval` step then the user discards the whole canvas:** the `ApprovalGate` resolves as cancelled (not skip, not approve); the loop ends like the executor's cancel path (`RuntimeError.cancelled` is not a failure). No side effect fires.
- **A `.auto` step whose `prepare` returns `.action` but `execute` throws** (e.g. permission denied on an auto calendar write): `.failed(headline)` with the clean `TaskError` message; the loop surfaces it and stops or continues per Decision 7 — never a false "Done."
- **Model never picks a tool (always `tool == ""`):** the very first route turn answers and stops — the common chat case; zero tool steps, zero cost beyond one route turn.
- **Cap reached mid-plan:** stream a best-effort answer noting the cap; the partial side effects that already committed are recorded (auditable downstream); the loop does not silently truncate.
- **Two candidates with identical `name`:** registry dedupes by `name` (first contributor wins); a name collision across contributors is a registration-time assertion in debug.
- **Reasoning flag:** the route turn carries `reasoning` from the active command/turn (like `TaskDispatcher.prepare`'s `reasoning:`), so a model that thinks-before-routing streams its plan into `.thinking` without changing the committed answer.

## Rejected alternatives

- **Gemma native function-call tokens.** Rejected: small models emit them unreliably, and `ai-command-tasks` already commits to "SHALL NOT depend on hard token-level caging to obtain structure." The `structured()` router (with repair/retry/decline) is the reliability mechanism; native tokens would fork the trust model and double the failure surface.
- **A new parallel `ToolDispatcher` separate from `TaskDispatcher`.** Rejected: it would duplicate the parse/review/execute/sink machinery the blueprint says to reuse wholesale and break the MLX-free/`StubLLMRuntime`-tested boundary. The contributor is a thin adapter instead.
- **Passing `argumentsJSON` straight to a sink, bypassing the kind's schema parse.** Rejected: it would let the router's (less reliable) JSON reach a side effect unvalidated. Folding args into the `resolvedPrompt` keeps the kind's `ParsedActions` schema as the authority — the existing validation/repair/decline stays in force.
- **All tools in front of the router every turn.** Rejected: blows the context budget and degrades small-model routing accuracy. Candidate retrieval (~5) is mandatory; the model widens via a routed tool step.
- **Defining `WritePolicyTier` in `ai-background-autonomy` and importing it here.** Rejected per integration fix C1: it creates a DAG back-edge (routing → autonomy) although routing is the earlier wave. The bare enum lives with `ToolDescriptor`; autonomy owns only resolution/audit/escalation.
- **A dedicated `RoutingError`/`AgentError` taxonomy.** Rejected: `RuntimeError` + `TaskError` carry every failure; a route-malformed is a graceful plain-answer fallback, not an error. Adding a taxonomy violates "at most one `<Slice>Error`, only if the existing ones cannot carry it."
- **A separate non-`.thinking` "plan" channel.** Rejected per blueprint (no third channel without cross-slice sign-off); the plan rides `.thinking`, which the canvas already renders.

## Target-split & verification summary

- **Everything in this slice is MLX-free Core**, verified by `swift build` + `swift test`. The router, loop, registry, contributor, candidate source, and contracts are pure value types + protocols driven by an injected `LLMRuntime`; tests inject `StubLLMRuntime` with **scripted structured outcomes** (`.value(route)` / `.declined`) and a fake `TaskDispatching` + scripted `ApprovalGate`.
- **No `xcodebuild`/`.app` work in this slice.** The MLX dependency is downstream (`ai-batched-runtime-and-context` provides the real `chat()` conformer the loop drives in production); compile-verify of that is owned there. To compile-check this slice in isolation without other in-flight slices' uncommitted files, use a throwaway `git worktree` + `swift build`.
- **No signing, no permission, no TCC interaction** — the slice never touches the build/sign path.

## Open Questions

- **Q1 (sequencing seam):** `ai-conversation-runtime` (`AgentMessage`/`AgentConversation`/`AgentTurn`) and `on-device-ai-runtime` (`LLMChatRequest`/`chat()`) are not yet committed on disk. I plan a narrow `ConversationContext`/`ChatStreaming` seam I own so the loop compiles + tests in isolation, then re-point it at the real types when they land. If the owners land first, I bind directly and delete the seam. Confirm the §3.1/§3.2 sketches are final enough to bind.
- **Q2 (descriptor identity for configured tasks):** I propose encoding the bound config in the descriptor `name` (e.g. `save_to_project:<project>`) so a routed call resolves deterministically back to a `TaskKind(+config)`. Alternative: a side table mapping descriptor → `(TaskKind, config)`. The side-table is cleaner but adds state; confirm preference.
- **Q3 (`maxToolSteps` default):** 8 is a guess balancing useful multi-hop against small-model spin. Tune in run-verify with the real batched runtime.
- **Q4 (candidate `limit`):** 5 per the prompt's "~3–5". Whether the active skill's allowed tools count against the 5 or are additive is a small policy choice I default to "additive, capped at 8 total" — confirm with `ai-skills-as-files`.
