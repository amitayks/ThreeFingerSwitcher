> Decomposed for a workflow fan-out: §1 is the type substrate (do first), §2–§6 are the router / registry / bridge / candidates / loop (each independent once §1 lands), §7 is the cross-slice seams, §8 verifies. Every item is MLX-free Core verified by `swift test` unless noted; NO `.app` build, NO signing.

## 1. Tool contracts (pure Core type substrate)

- [x] 1.1 Add `AI/Agent/ToolContracts.swift`: `WritePolicyTier` (`auto`/`confirm`/`dangerous`), `ToolDescriptor{name, summary, argsSchema: StructuredSchema, writePolicy, keywords}`, `ToolRoute{tool, argumentsJSON, rationale?}` (+ `isPlainAnswer`), `ToolStepResult{tool, status, summary}`, `ToolStepStatus{done, awaitingApproval, declined(reason), failed(headline)}`, `RoutedCall`, `RouteContext`. All `Codable`/`Equatable`/`Sendable`. Bare `WritePolicyTier` lives HERE (integration fix C1). *Verify: `swift test` — Codable round-trip + Equatable for each type.*
- [x] 1.2 Doc-comment that `WritePolicyTier` is OWNED here and `ai-background-autonomy` consumes it for resolution/audit/escalation only (no redefinition). *Verify: review.*

## 2. The route turn (`structured()` as router)

- [x] 2.1 Add `AI/Agent/RouteSchema.swift`: the fixed `RouteSchema` `StructuredSchema` (`required: ["tool"]`, properties `tool`/`argumentsJSON`/`rationale`) mirroring `ParsedActions.swift` style; plus a pure route-prompt builder that renders the candidate descriptors (name + summary + `argsSchema.json`) + the conversation tail + the "choose one or answer directly" instruction. *Verify: `swift test` — the built prompt contains each candidate's name + schema and the empty-tool instruction.*
- [x] 2.2 Add `AI/Agent/ToolRouter.swift`: `ToolRouter.route(context, candidates, runtime, reasoning) async -> ToolRoute` calling `runtime.structured(LLMRequest(prompt:reasoning:), schema: RouteSchema, as: ToolRoute.self)`; map `.value(tool=="")` / `.declined` / `couldNotProduceValid` / unknown-tool → plain answer; non-empty matched tool → routed call; other throws → mapped failure (via `AIError.message(for:)`). `RuntimeError.cancelled` is not a failure. *Verify: `swift test` with scripted `StubLLMRuntime` for each outcome branch.*

## 3. Registry + approval gate

- [x] 3.1 Add `AI/Agent/ToolRegistry.swift`: `ToolContributor` protocol (`descriptors()`, `canHandle(_:)`, `run(_:gate:)`), `ToolRegistry` (aggregate `allDescriptors()`, dedupe by `name` first-wins, `descriptor(named:)`, `run(_:gate:)` routing to the owning contributor), and the async `ApprovalGate` seam (`awaitDecision() -> .approve/.skip/.cancel`). *Verify: `swift test` — aggregation, name dedupe, dispatch to the right contributor, unknown tool returns a defensive `.failed`/skip.*
- [x] 3.2 Add a `ScriptedApprovalGate` test double (deterministic approve/skip/cancel queue). *Verify: used by §4/§6 tests.*

## 4. Bridge to the existing task machinery (the load-bearing reuse)

- [x] 4.1 Add `AI/Agent/TaskKindToolContributor.swift`: build `ToolDescriptor`s for the existing `TaskKind`s (calendar/reminder/contact = `.confirm`; saveToProject/openToolWithPayload/sendTo carry their bound config in the descriptor identity per Decision Q2; default `.confirm`). *Verify: `swift test` — one descriptor per authored task; config round-trips to the right `TaskKind`.*
- [x] 4.2 Implement the args→`resolvedPrompt` fold: render `ToolRoute.argumentsJSON` into the prompt the existing `TaskDispatching.prepare` consumes (args are a hint; the kind's `ParsedActions` schema stays the authority). DO NOT modify `TaskDispatcher`/`ParsedActions`/`TaskSinks`. *Verify: `swift test` with a fake `TaskDispatching` asserting the folded prompt; confirm zero changes to existing task files (`git diff` empty for those).*
- [x] 4.3 Map `TaskReview` → `ToolStepResult` + gate: `.declined`→`.declined`; `.unavailable`→`.failed(headline)`; `.action` with effective `.auto`→`execute` now→`.done` (or `.failed` if `execute` throws — never a false Done); `.action` with `.confirm`/`.dangerous`→`.awaitingApproval`, await the gate, approve→`execute`, skip→`.declined("skipped")`, cancel→ends the loop (not a failure). *Verify: `swift test` — each branch with scripted dispatcher + gate.*

## 5. Write-policy gate + candidate retrieval

- [x] 5.1 Add `AI/Agent/WritePolicyResolving.swift`: the `WritePolicyResolving` seam + `DescriptorWritePolicy` stand-alone default (returns the descriptor's own tier), so the slice compiles + tests without `ai-background-autonomy`. *Verify: `swift test`.*
- [x] 5.2 Add `AI/Agent/ToolCandidateSource.swift`: `ToolCandidateSource` protocol + `KeywordToolCandidateSource` (lexical match of the latest user turn vs descriptor `name`/`summary`/`keywords`, top-`limit` default 5, always include the active skill's allowed tools, additive cap 8). Shape mirrors `DocIndex.retrieve(query:limit:)` (blueprint §3.4). *Verify: `swift test` — ranking, top-N, skill-allowed inclusion, cap.*
- [x] 5.3 Add the `widen_candidates`/`retrieve` `ToolDescriptor` so the model can request a broader set (retrieval-as-a-routed-step); the registry's `run` for it re-feeds a wider candidate set into the next loop step. *Verify: `swift test` — a route to `widen_candidates` enlarges the next turn's candidates.*

## 6. The bounded agent loop

- [x] 6.1 Add `AI/Agent/AgentLoop.swift`: the pure route→execute→continue loop with `maxToolSteps` (default 8); plain-answer termination on `tool==""`; per-step `registry.run` + appended `.tool` context; `AgentLoopOutcome{answered(text), stopped(reason), failed(headline), capReached}`. *Verify: `swift test` — plain-answer one-shot, single tool step, multi-hop, cap reached.*
- [x] 6.2 Emit `route.rationale` + each `ToolStepResult.summary` into the `.thinking` channel (NO third channel); publish the ordered `[ToolStepResult]` + current `.awaitingApproval` review as observable loop state for the canvas. *Verify: `swift test` — thinking accumulates the plan; response carries only the final answer.*
- [x] 6.3 Loop-guard / no-progress: end `.stopped(.repeatedStep)` on a byte-identical consecutive route; end `.stopped(.noProgress)` on re-routing to a tool that just declined/failed > once; always stream a best-effort final answer on any termination (never a bare halt). *Verify: `swift test` — repeated-step and declined-re-route termination; cap backstop.*
- [x] 6.4 Cancellation: a gate `.cancel` / `RuntimeError.cancelled` ends the loop quietly (not `.failed`), fires no side effect. *Verify: `swift test`.*

## 7. Cross-slice seams (compile-in-isolation today, bind later)

- [x] 7.1 Add `AI/Agent/ConversationSeam.swift`: narrow `ConversationContext`/`ChatStreaming` protocols this slice OWNS until `ai-conversation-runtime`/`on-device-ai-runtime` commit `AgentMessage`/`AgentConversation`/`LLMChatRequest`/`chat()`; appending a `.tool` turn goes through this seam. *Verify: `swift test`; documented to be re-pointed at the real types (Open Question Q1).*
- [x] 7.2 Document the consumer seams other slices plug into: `ToolContributor` (memory / skills / handoff register here), `WritePolicyResolving` (autonomy supplies the whitelist-intersecting resolver), `ToolCandidateSource` (skills/memory supply a `DocIndex`-backed source), `ApprovalGate` (the canvas drives DOWN=approve/RIGHT=skip). *Verify: review against blueprint §5.*

## 8. Verify

- [x] 8.1 `swift build` + `swift test` green; the router (every outcome branch), the bridge (each `TaskReview`→`ToolStepResult`), the gate (approve/skip/cancel), candidate ranking, the loop (plain-answer / multi-hop / cap / loop-guard), and the `.thinking` plan split are all covered by scripted `StubLLMRuntime` outcomes + fakes. *Verify: `swift test`.*
- [x] 8.2 Confirm the existing task files (`TaskDispatcher.swift`, `ParsedActions.swift`, `TaskSinks.swift`, `TaskReview.swift`, `TaskDispatching.swift`, `AICommandExecutor.swift`) are **unmodified** by this slice (reuse wholesale, no fork). *Verify: `git diff --stat` shows no changes to those files.*
- [x] 8.3 `openspec validate --strict` passes; the `ai-command-tasks` delta's ADDED requirements + scenarios match the implemented contracts. *Verify: `openspec validate --strict`.*
- [x] 8.4 **No `.app` build, no signing, no permission change** performed by this slice — verification is `swift test` only; the MLX-linked real-runtime compile is owned by `ai-batched-runtime-and-context`. *Verify: review.*
- [ ] 8.5 **User run-verify** (later, after the real batched runtime + canvas land, in a stable-signed build): a conversational ask routes to the right tool, read-only steps auto-run, a side-effecting step waits for a DOWN approve / RIGHT skip, the plan shows in the Thinking section, and a spin terminates at the cap with a clean summary. *(Deferred — depends on downstream slices.)*
