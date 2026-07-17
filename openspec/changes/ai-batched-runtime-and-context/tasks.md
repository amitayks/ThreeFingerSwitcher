> Decomposed for a workflow fan-out: §1–§3 are the pure-Core substrate (do first, all `swift test`), §4 is the MLX-linked conformer (`xcodebuild` compile-verify only), §5 is the user-facing context tuning, §6 is the subagent primitive, §7 wires the provisioner, §8 verifies. The batched conformer (§4) requires the user's stable-signed build for real validation — the agent compile-verifies only.

## 1. `BatchedLLMRuntime` protocol + memory budget (pure Core)

- [x] 1.1 Add the `BatchedLLMRuntime` protocol (blueprint §3.6) to `AI/LLMRuntime.swift` (Core, MLX-free): `batchStep(_:[AgentSessionID:LLMChatRequest]) -> AsyncThrowingStream<(AgentSessionID, Token), Error>` + `var maxConcurrentStreams: Int`. It refines `LLMRuntime`; consumes `LLMChatRequest` + `AgentSessionID` verbatim from `ai-conversation-runtime` (do NOT redefine). *Verify: `swift build`.*
- [x] 1.2 Add `KVCacheCost` (Core): `slidingLayers`/`globalLayers`/`slidingWindow`/`kvBytesPerTokenPerLayer` + `kvBytes(forContext:)` implementing the Gemma interleaved sliding-window/global sum (D3). *Verify: `swift test` — uniform-global vs interleaved differ; sliding KV clamps at the window.*
- [x] 1.3 Add `ConcurrencyBudget` (Core): `maxStreams(contextTokens:)` = floor((free − weights − reserved) / kvBytes(ctx)), **clamped ≥ 1**; `estimatedRAM(streams:contextTokens:)`. Memory probe is injected (no Metal). *Verify: `swift test` — K decreases monotonically as context grows; K ≥ 1 even at model-max; estimatedRAM tracks streams×KV + weights.*
- [x] 1.4 Add a deterministic `StubBatchedRuntime` (Core, test-only) conforming to `BatchedLLMRuntime` that scripts per-stream token sequences. *Verify: `swift test` — K streams de-mux to the right `AgentSessionID`; a finished stream frees its slot for a queued one.*

## 2. `ModelDescriptor.maxContextTokens` (pure Core)

- [x] 2.1 Add `maxContextTokens: Int` to `ModelDescriptor` (AI/ModelRegistry.swift) and set real values on the `.standard` registry entries (Gemma 4's architectural max). *Verify: `swift test` — registry constructs; the field round-trips.*
- [x] 2.2 Confirm additive: existing `ModelDescriptor` construction sites still compile (it has an explicit init). *Verify: `swift build` + `xcodebuild` compile (GemmaRuntime's `pipelineModel(for:)` unaffected).*

## 3. Concrete context-budget provider + per-skill override seam (pure Core)

- [x] 3.1 Add `AgentContextBudgetProvider` conforming to `ai-conversation-runtime`'s `ContextBudgetProviding` (integration fix C3 — consume that protocol, do NOT redefine it): `maxContextTokens` resolves the effective budget = `agentContextTokens` ∩ `ModelDescriptor.maxContextTokens` ∩ per-skill override. *Verify: `swift test` — effective budget is the clamped min; an oversized slider clamps to model max.*
- [x] 3.2 Add a small `SkillContextOverriding` read seam (Core) — reads an optional context-override off the active skill (the value rides on the skill file owned by `ai-skills-as-files`; this slice only reads it). Default provider returns nil. *Verify: `swift test` — `max(globalDefault, skillOverride)` clamped to model max; nil override → globalDefault.*
- [x] 3.3 Wire the provider into a `ai-conversation-runtime` compaction test (inject this provider instead of the fixed stub) to prove growing the budget raises the compaction trigger. *Verify: `swift test` — a larger budget defers compaction; a smaller one triggers it sooner.*

## 4. `BatchedGemmaMLXRuntime` conformer (GemmaRuntime — `xcodebuild` compile-verify ONLY)

> MLX-linked. The agent NEVER builds/signs/installs the `.app` (ad-hoc signing breaks TCC grants). Real validation (live batching, KV-quant quality, no cross-stream bleed) requires the **user's stable-signed build** — see §8.3. The metallib bundle landmine stands: no change to `build-app.sh`'s `*.bundle` → `Contents/Resources/` copy.

- [x] 4.1 Add `BatchedGemmaMLXRuntime` (GemmaRuntime target) conforming to `LLMRuntime` + `BatchedLLMRuntime`; subsume `GemmaMLXRuntime`'s single-session paths (text fast path, vision manual loop, reasoning channel classifier). *Verify: `xcodebuild` compile.*
- [x] 4.2 Implement the continuous-batching decode loop (D2): slot assignment (foreground slot 0, rest from `ParkScheduler.runnableSessions`), one batched forward pass per step (weights read once), per-stream sampling + de-mux to `(AgentSessionID, Token)`, mid-flight admit/free of slots, chunked prefill interleaved with decode. *Verify: `xcodebuild` compile; **user run-verify** (§8.3).*
- [x] 4.3 Implement per-stream **quantized** KV caches (8/4-bit, D3), selected by the compact-KV setting (8-bit) with 4-bit reserved for the rotating-window background path. Expose the per-layer sliding/global split to `ConcurrencyBudget`. *Verify: `xcodebuild` compile; **user run-verify** quality + RAM.*
- [x] 4.4 Implement **prefix/prompt caching** of the shared system+skills prefix (D3): compute prefix KV once, key by prefix-text hash, reuse across turns/sessions, invalidate on hash change. *Verify: `xcodebuild` compile; **user run-verify** repeated turns skip prefix prefill.*
- [x] 4.5 Implement the optional **rotating fixed-window KV** for unbounded background threads (D3) — bounded GPU cache independent of compaction. *Verify: `xcodebuild` compile; **user run-verify** a long background thread holds bounded KV.*
- [x] 4.6 Compute `maxConcurrentStreams` from `ConcurrencyBudget` against the live free-memory probe + current context setting + KV-quant bits (D1/D4); recompute on context-setting change / memory pressure. *Verify: `xcodebuild` compile; **user run-verify** K drops as context grows.*
- [x] 4.7 Map MLX/OS/OOM failures to `RuntimeError` at the conformer boundary; a stream error is per-stream terminal (the rest of the batch continues), surfaced via `AIError.message(for:)` — never a batch-wide abort, never a false "done," never `NSAlert` (D8). *Verify: `xcodebuild` compile; `swift test` on the Core de-mux/feedback path with the stub.*

## 5. Context tuning settings + Hub cost surface (Core + app UI)

- [x] 5.1 Persist `agentContextTokens` (Int), `agentContextPreset` (Balanced/Long/Max/custom; default **Balanced**), `agentCompactKV` (Bool; default off) in `AppSettings` — clamp to model max; included in **reset-to-defaults**; legacy settings decode with defaults. *Verify: `swift test` — defaults, clamp, reset, legacy decode.*
- [x] 5.2 Hub AI-page controls: the preset segmented control + the "compact long contexts (8-bit KV)" toggle, writing the persisted keys. Secondary model-management controls unchanged. *Verify: `xcodebuild` compile.*
- [x] 5.3 Hub **cost surface** (house requirement — never silent OOM): show estimated RAM + concurrent-stream count (from `ConcurrencyBudget`) + a relative speed note for the chosen context, updating live with the preset/toggle (D5). *Verify: `xcodebuild` compile; **user run-verify** the numbers track the chosen preset.*
- [x] 5.4 Per-skill context override: surface that a heavy skill may raise the effective context (read-only display via `SkillContextOverriding`); the value is authored on the skill file (`ai-skills-as-files`). *Verify: `xcodebuild` compile; `swift test` covers the resolution in §3.2.*

## 6. `Subagent` fixed-pattern primitive (pure Core)

- [x] 6.1 Add `Subagent` (name + systemPrompt + bounded `maxTurns`) and `SubagentResult` (summary + sessionID) (D7) — runs a sub-task in a **fresh** `AgentConversation`, returns only a summary `AgentMessage`. Fixed named set; **no** dynamic/recursive spawning. *Verify: `swift test` — orchestrator context excludes the subagent's intermediate turns; only the summary returns; `maxTurns` bounds it.*
- [x] 6.2 Expose "run subagent X" as a `ToolDescriptor`-shaped capability so it is invokable as a routed tool step (`ai-tool-routing` consumes it); a subagent rides a batch slot like any other session (concurrency-cheap, context-cheap). *Verify: `swift test` — the tool returns a `ToolStepResult` carrying the summary; `xcodebuild` compile for the GemmaRuntime slot usage.*

## 7. Provisioner wiring (GemmaRuntime — `xcodebuild` compile-verify)

- [x] 7.1 Change `GemmaRuntime.makeModelManager`'s `ModelProvisioner` to construct and `prepare` a `BatchedGemmaMLXRuntime` instead of `GemmaMLXRuntime` (D9) — **no `ModelManager` API change**; residency/lifecycle/registry behavior identical. *Verify: `xcodebuild` compile; the full product links Core + GemmaRuntime.* **(wire-full-potential-gates: now GATED — the provisioner constructs `BatchedGemmaMLXRuntime` ONLY when `batchedRuntimeUnlocked` (the already-resolved `FullPotentialGate.isUnlocked(.batchedRuntime)`, threaded via `AIRuntimeInjection.modelManagerFactory(optedIn:cpuLaneUnlocked:batchedRuntimeUnlocked:)` + `main.swift`); LOCKED (default master OFF) → the proven single-session `GemmaMLXRuntime` is resident, so the K-stream / growable-context surface is never constructed and the build behaves exactly as today's single-session one — the calm panic-off, no error. `xcodebuild` GREEN.)**
- [x] 7.2 The scheduler-driven background advancer downcasts `ModelManager.currentRuntime as? BatchedLLMRuntime` to drive `batchStep`; the foreground `chat()` path uses the base `LLMRuntime`. *Verify: `xcodebuild` compile; `swift test` for the Core-side downcast guard logic with the stub.*

## 8. Verify

- [x] 8.1 `swift build` + `swift test` green: `ConcurrencyBudget`/`KVCacheCost` (monotonic K, interleaved KV, clamp ≥1), the context-budget provider (effective-budget resolution + the conversation-runtime compaction tie-in), the `Subagent` isolation, the `StubBatchedRuntime` de-mux/slot-free, settings defaults/clamp/reset/legacy. *Verify: `swift test`.*
- [x] 8.2 `xcodebuild` compile-verify only: the full `ThreeFingerSwitcher` product builds + links (Core + GemmaRuntime/MLX) with `BatchedGemmaMLXRuntime` and the provisioner change. The agent does NOT build/sign/install the `.app`. *Verify: `xcodebuild` (compile).*
- [ ] 8.3 **User run-verify in a stable-signed build** (`INSTALL=1 ./scripts/build-app.sh`): the foreground session + ≥1 parked session advance together (one weight read, not N×); KV-quant + prefix caching hold; growing the context preset visibly lowers the background-stream count and the Hub cost surface tracks it; a heavy skill's per-skill override raises the effective context; a single stream's failure does not abort the batch. *Verify: user-build (required — Metal + TCC + live batching cannot be agent-verified).*
- [x] 8.4 `openspec validate --strict` passes; the `on-device-ai-runtime` ADDED requirements and the `tunable-settings` ADDED requirement match the implementation. *Verify: `openspec validate --strict`.*
