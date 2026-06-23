> Wave 1 of the V2 agent. §1–§3 are the canonical types + runtime seam (the type home other slices import); §4 is compaction; §5 evolves the executor into a session; §6 makes the Stub multi-turn; §7 is the tool-type hand-off seam; §8 verifies. All MLX-free Core unless noted — `swift build`/`swift test` is the verification, with `xcodebuild` compile-verify only to confirm the additive seam doesn't break the GemmaRuntime conformer. The agent NEVER builds/signs/installs the `.app`.

## 1. Canonical conversation types (Core)

- [x] 1.1 Add `AI/Agent/AgentConversation.swift` with `AgentRole`, `AgentMessage`, `AgentSessionID`, `AgentConversation`, `AgentTurn` EXACTLY as blueprint §3.1 / design D1 (Core, MLX-free, `Codable`/`Equatable`/`Sendable`; `AgentMessage`/`AgentConversation` also `Identifiable`). `text` = re-fed content; `thinking` = display-only; thinking is structurally separate so it is never re-fed. Verify: `swift test` Codable round-trip + equality.
- [x] 1.2 Document the invariant on the type (doc comment): assembly reads `text` only; `thinking` is never re-fed as ground truth. Verify: review + the assembly test (4.x/5.x).
- [x] 1.3 Unit-test the types: Codable round-trip preserves all fields incl. `compactedSummary`/`skillID`/`image`; `AgentSessionID` Hashable stable; equality. Verify: `swift test`.

## 2. Runtime messages seam (Core)

- [x] 2.1 Add `LLMChatRequest{messages, image, parameters, reasoning, tools}` to `AI/LLMRuntime.swift` (blueprint §3.2 / design D2), `Sendable`. `tools` declared in final shape, ignored by this slice. Verify: `swift build`.
- [x] 2.2 Add the default-implemented `extension LLMRuntime { func chat(_:) -> AsyncThrowingStream<Token,Error> }` that flattens messages via `ChatTemplate.flatten` and calls `generate(_:)`, passing `image`/`reasoning`/`parameters` through (so channel split + vision are inherited). Verify: `swift test` (default path streams), `xcodebuild` (Gemma conformer + app still compile against the additive seam).
- [x] 2.3 Confirm `StubLLMRuntime`, `DevAIRuntime`, and the existing Gemma conformer compile UNCHANGED against the additive `chat` (no override required for them). Verify: `swift build` + `xcodebuild` compile-only.

## 3. Chat-template assembler (Core)

- [x] 3.1 Add `AI/Agent/ChatTemplate.swift` with `static func flatten(_ messages: [AgentMessage]) -> String` (design D3): deterministic role-labeled transcript reading `message.text` ONLY; `.tool` messages render `toolResult?.summary`; trailing `Assistant:` cue. Pure/`nonisolated`/static. Verify: `swift test`.
- [x] 3.2 Mark the real Gemma chat-template (`<start_of_turn>` markers + `enable_thinking` flag) as FLAGGED for the GemmaRuntime / `ai-batched-runtime-and-context` slice with a `// FLAGGED: GemmaRuntime` note; this slice ships only the Core flatten-default. Verify: review; spec scenario references the flag.
- [x] 3.3 Unit-test `flatten`: role ordering preserved; a turn's `thinking` NEVER appears in the output; tool-line rendering; trailing cue present; empty list → empty/cue-only. Verify: `swift test`.

## 4. Compaction (Core — this slice OWNS it)

- [x] 4.1 Add `AI/Agent/ContextBudget.swift`: `protocol ContextBudgetProviding { var maxContextTokens: Int }` (the INJECTED budget seam, integration fix C3 — never the concrete `agentContextTokens` slider), a pure `TokenEstimator` (estimates `text` only, with a safety margin), and a default constant-budget provider so the slice builds standalone. Verify: `swift test` (estimate grows with content; margin applied).
- [x] 4.2 Add `AI/Agent/ConversationCompactor.swift`: pure `needsCompaction(_:budget:) -> Bool` (assembled estimate incl. existing summary crosses the margin-adjusted budget) and pure `plan(_:budget:) -> CompactionPlan` (keep most-recent `keepRecentTurns` verbatim; collapse the older prefix incl. any prior summary into the to-summarize input). Verify: `swift test` (deterministic with a fixed-budget stub).
- [x] 4.3 Add `summarize(_ plan:runtime:) async throws -> String` — a single `runtime.generate` call (reasoning OFF) condensing the to-summarize slice; map errors through `RuntimeError`/`AIError`. Apply: set `compactedSummary`, replace `messages` with the kept tail. Verify: `swift test` (Stub-scripted summary; a thrown error propagates and does NOT drop history).
- [x] 4.4 Unit-test compaction end-to-end with a fixed-budget stub: a long thread triggers `needsCompaction`; `plan` keeps recent N; `summarize` produces the prefix; the next assembly carries the summary as a `system` prefix and the dropped raw turns are gone; thinking never enters the summary input. Verify: `swift test`.

## 5. Executor → session (Core)

- [x] 5.1 Add `private(set) var conversation: AgentConversation?` to `AICommandExecutor` (in-memory thread; durable storage is `ai-parked-sessions`). Verify: `swift build`.
- [x] 5.2 Add additive `State` cases `.conversing(partial: String)` and `.awaitingTurn` + extend the hand-written `==` for them; leave ALL existing one-shot cases (`.streaming`/`.ready`/`.committed`/`.reviewingAction`/`.declined`/`.failed`/`.unavailable`/`.noInput`) and `isCommittable` unchanged. (`.awaitingApproval`/`.parked` are owned by tool-routing/canvas — NOT added here.) Verify: `swift test` (existing one-shot tests stay green) + `swift build`.
- [x] 5.3 Add `startConversation(seedText:image:parameters:reasoning:)` — open `AgentConversation` with turn-1 user `AgentMessage` from the SAME acquisition + `PromptTemplate.resolve` seed the one-shot path uses; empty-and-imageless seed → `.noInput` (preserved). Verify: `swift test`.
- [x] 5.4 Add the private `runTurn()` loop (design D4): append the user turn, compact-if-needed (§4), assemble (§5.5), stream `chat` splitting `.thinking`→live `thinking` / `.response`→`.conversing(partial:)`, then append the assistant `AgentMessage(text: response, thinking: reasoning-or-nil)` and go `.awaitingTurn`. Per-turn cancellation: a mid-turn discard appends NO assistant message and is not a failure. A non-cancel error → `.failed(AIError.message(for:).headline)`. Verify: `swift test`.
- [x] 5.5 Add `assembleRequest()` (design D5): build `LLMChatRequest` from `conversation.messages` reading `text` ONLY, prefixing `compactedSummary` as a synthetic `system` message; latest image; resolved reasoning (reuse `command.resolvedReasoning(globalDefault:)`); `GenerationParameters` as today. Verify: `swift test` (turn-2 assembly contains turn-1 text; never any `thinking`).
- [x] 5.6 Add `continueConversation(_ userText:)` (the next-turn entry the canvas slice calls on Enter=send) → append user turn → `runTurn()`. Reset live `thinking` at each turn start so a new turn never shows the prior turn's reasoning. Verify: `swift test` (two-turn scripted conversation; live thinking resets between turns).
- [x] 5.7 Per-turn `.failed`: a scripted turn error transitions to `.failed` with a clean headline (never silence, never a false continuation); cancellation stays benign. Verify: `swift test`.

## 6. Multi-turn Stub (Core)

- [x] 6.1 Add `scriptedTurns: [TurnScript]` (FIFO, each `{tokens, thinking}`) to `StubLLMRuntime`; each `generate` dequeues one; queue exhausted → fall back to legacy `scriptedTokens` (existing single-gen tests byte-identical). Add a `scriptedSummary`/reserved-turn hook for the compaction call, and a per-turn throw hook for per-turn `.failed`. The default `chat` (flatten→generate) consumes the queue through `generate` — no Stub `chat` override. Verify: `swift test`.
- [x] 6.2 Keep per-call cancellation observation working per turn (a mid-turn discard stops emitting). Verify: `swift test` (cancel mid-turn-2; no assistant message appended).

## 7. Tool-type hand-off seam (Core, temporary)

- [x] 7.1 Introduce minimal placeholder value types `ToolRoute`/`ToolStepResult`/`ToolStepStatus`/`ToolDescriptor`/`WritePolicyTier` in `AI/Agent/ToolPlaceholders.swift` EXACTLY as blueprint §3.3/§3.7 sketch them, so `AgentMessage.toolCalls`/`.toolResult` and `LLMChatRequest.tools` compile standalone (design D9). Mark the file `// HAND-OFF: ai-tool-routing takes ownership; do not change the shapes here`. Verify: `swift build`.
- [x] 7.2 Document (in the file + the spec delta) that `ai-tool-routing` (Wave 2) takes ownership of these types and the route loop, with the shapes unchanged. Verify: review; cross-slice note in the spec.

## 8. Verify

- [x] 8.1 `swift build` + `swift test` green: the canonical types, `flatten`, compaction (windowing/plan/summarize), the executor session machine (multi-turn, per-turn cancel, per-turn fail, compaction trigger, thinking-exclusion), and the multi-turn Stub are all covered. Existing one-shot executor + runtime tests stay green. Verify: `swift test`.
- [x] 8.2 `xcodebuild` compile-verify the full `ThreeFingerSwitcher` product (Core + GemmaRuntime/MLX) so the additive `chat`/`LLMChatRequest` seam is confirmed not to break the existing Gemma conformer (compile ONLY — the agent never signs/installs). Verify: `xcodebuild` compile.
- [x] 8.3 `openspec validate --strict` passes; the `on-device-ai-runtime` delta (ADDED/MODIFIED requirements + scenarios) matches the implementation. Verify: `openspec validate --strict`.
- [ ] 8.4 **User run-verify** (stable-signed build, optional until a consumer slice surfaces the UX): a multi-turn conversation continues across turns with the model seeing prior turns; thinking shows live but is never re-fed; a long thread compacts without overflow; a mid-turn discard leaves no half-message. (This slice has no UI of its own — the canvas slice surfaces it; this is a smoke check via a debug harness if available.)
