## Context

The on-device runtime today is a single `LLMRuntime` conformer (`GemmaMLXRuntime`, GemmaRuntime target) that serves **one** request at a time: `generate(_:)` runs a per-token decode loop on one resident graph. `ModelManager` (Core, `@MainActor`) owns weights/residency and injects the real runtime through an existing `ModelProvisioner` seam — `GemmaRuntime.makeModelManager` builds the provisioner that creates and `prepare`s a `GemmaMLXRuntime`. Feature code only ever sees `LLMRuntime` (design D1).

V2 needs **concurrency** (foreground session + parked background sessions advancing) and **long context** (skills + memory TOC + a long thread). Two facts drive the architecture:

- **Decode is memory-bandwidth-bound.** One decode step reads the whole ~17 GB weight set from unified memory to emit *one* token per stream. The 16 GPU cores are mostly idle waiting on that read. K independent `generate()` calls each re-read the weights → K× bandwidth, no win. **Continuous batching** reads the weights **once** and advances K streams together — the cores do K× the arithmetic against the one weight read. This is the only correct concurrency primitive here.
- **RAM is the concurrency ceiling.** 48 GB unified = weights (once, ~17 GB at 4-bit) + **K** KV caches. The KV cache is per-stream and grows linearly with context length. So K is **derived from free RAM at a given context length**, not a constant — and growing context shrinks K. This is why context tuning and concurrency are one slice.

`ai-conversation-runtime` already landed the seam shapes this slice plugs into: `LLMChatRequest` + a default-flattened `LLMRuntime.chat()` (blueprint §3.2), the `AgentMessage`/`AgentSessionID`/`AgentConversation`/`AgentTurn` types, and — crucially — its compaction reads the token budget through an **injected `ContextBudgetProviding`** (integration fix C3), explicitly so it does not depend on this slice landing first. This slice ships the **concrete** provider (backed by `ModelDescriptor.maxContextTokens` ∩ the user's `agentContextTokens`) and the batched conformer that **overrides** `chat()` for true KV-reuse multi-turn. `ai-parked-sessions` owns `ParkScheduler`; this slice **consumes** `runnableSessions(now:maxSlots:)` to fill batch slots and reports back via `didAdvance`.

## Goals / Non-Goals

**Goals:**
- A `BatchedLLMRuntime` conformer that multiplexes K sessions over one weight read per decode step, de-multiplexing tokens by `AgentSessionID`, with the foreground session always slotted and the rest fed by `ParkScheduler`.
- A pure, testable **memory budget** that derives K from weights + free RAM + per-token KV cost (a function of context length and KV-quant bits), accounting for Gemma's interleaved sliding-window/global attention.
- KV-cache quantization (8/4-bit), prefix/prompt caching of the shared system+skills prefix, and a rotating fixed-window KV option — all internal to the GemmaRuntime conformer.
- User-adjustable context (presets Balanced/Long/Max + compact-KV toggle), clamped to the model max, with the RAM/speed cost surfaced; a global default + per-skill override; the effective budget feeding conversation-runtime compaction through the injected provider.
- A `Subagent` fixed-pattern primitive: run a sub-task in a fresh context, return only a summary.

**Non-Goals:**
- The conversation state machine / compaction *logic* (owned by `ai-conversation-runtime`; this slice only supplies the budget number through the provider).
- The parked-session durable store, the notch rail, and park/restore lifecycle (`ai-parked-sessions`); this slice only *consumes* `ParkScheduler`.
- The route→execute→continue loop and tool execution (`ai-tool-routing`).
- The skill file format (`ai-skills-as-files`); this slice reads only an optional per-skill context-override value off the resolved skill.
- Open-ended, model-driven recursive subagent spawning — the primitive is fixed-pattern and bounded on purpose (a small model orchestrates dynamic spawning poorly).
- Any Intel / low-end / non-Metal fallback or defensive degraded decode path. The target is M5/M4 only.
- A cloud/remote runtime, or video/audio batching.

## Decisions

### D1. `BatchedLLMRuntime` is a Core protocol; the conformer is GemmaRuntime.

The **protocol** (blueprint §3.6) lives in MLX-free Core alongside `LLMRuntime` so feature code and the scheduler can reference `maxConcurrentStreams` and the batched entry point without linking MLX:

```
public protocol BatchedLLMRuntime: LLMRuntime {
    func batchStep(_ requests: [AgentSessionID: LLMChatRequest])
        -> AsyncThrowingStream<(AgentSessionID, Token), Error>
    var maxConcurrentStreams: Int { get }   // K — derived from RAM (D4), not a constant
}
```

The **conformer** `BatchedGemmaMLXRuntime` (GemmaRuntime target, MLX-linked) implements it plus `chat()` (the single-session entry — it just runs a one-element batch) and the inherited `generate`/`structured`. It is the new resident runtime the provisioner returns; it subsumes `GemmaMLXRuntime`'s single path (vision, reasoning channels, the manual loop) and adds the batched decode loop. Verified by `xcodebuild` compile-only — an agent never builds/signs/installs the `.app`.

- **`maxConcurrentStreams` is RAM-derived, not constant.** It reads `ConcurrencyBudget` (D4) against the current `agentContextTokens` and KV-quant bits, so growing context lowers K honestly. It is recomputed when the context setting changes or memory pressure is reported.

### D2. Continuous batching: one weight read, K streams, per-stream de-mux.

The decode loop (inside the conformer) is the classic continuous-batching loop:

1. **Slot assignment.** The foreground active session (if any) takes slot 0 unconditionally. Remaining `maxConcurrentStreams - 1` slots are filled from `ParkScheduler.runnableSessions(now:maxSlots:)`. New requests can join **mid-flight** (continuous, not static batching): a stream that finishes (`isFinal`) frees its slot for the next runnable session on the very next step — the weights stay resident, no reload.
2. **Per-step forward pass.** Each active stream contributes its next-token query; the K queries are stacked into one batched forward pass that reads the weights **once**. Padding/masking handles unequal sequence lengths; a per-stream KV cache (D3) holds each stream's keys/values.
3. **De-mux.** The pass yields one logit row per stream → one sampled `Token` per stream, emitted as `(AgentSessionID, Token)` on the merged stream. Channel classification (`.thinking`/`.response`, the existing `ChannelClassifier` idiom) is per-stream.
4. **Prefill vs decode.** A newly admitted stream first runs a **prefill** (its full prompt) to populate its KV cache; thereafter it joins the single-token decode batch. Prefill of a new stream and decode of running streams are interleaved so admitting a session never stalls the others for long (chunked prefill, bounded chunk size).
5. **Feedback.** On each stream's `isFinal`, the conformer calls `ParkScheduler.didAdvance(id, result:)` so the scheduler can re-rank; a stream error maps to `RuntimeError` and is emitted as that stream's terminal token-stream error (the other streams are unaffected — failure is per-stream, never a batch-wide abort).

`chat()` for a single foreground turn is just `batchStep([id: request])` with K=1 — the same code path, so the foreground multi-turn case reuses the KV cache across turns (the win conversation-runtime wants).

### D3. KV cache: per-stream, quantized, prefix-cached, rotating-window option.

The KV cache is the per-stream memory cost and the long-context lever. Three mechanisms, all internal to the conformer:

- **KV quantization (8/4-bit).** Keys/values are stored quantized (MLX `quantized_kv` / quantized-cache idiom). 8-bit ≈ halves KV bytes vs bf16 with negligible quality loss; 4-bit quarters it for the longest threads. The **compact-KV toggle** (D6) selects 8-bit; "Max" context may force it. Per-token KV bytes feed `ConcurrencyBudget` (D4).
- **Prefix / prompt caching.** The shared **system + skills prefix** (the combined TOC of `allSummaries()` from `ai-skills-as-files`/`ai-agent-memory`, plus the system preamble) is identical across turns and often across *sessions*. Its KV is computed **once** and reused: a turn's prefill skips the cached prefix and only prefills the turn-specific suffix. This is the single biggest per-turn latency win for long static prefixes; it is keyed by a hash of the prefix text so a changed prefix invalidates cleanly.
- **Rotating fixed-window KV (optional).** For unbounded background threads, a fixed-window (ring-buffer) KV caps the cache at the last W tokens — bounded memory regardless of how long a parked session runs. This is a *runtime* cap distinct from conversation-runtime's *compaction* (which rewrites history): the window bounds the GPU cache; compaction bounds the re-fed token count. They compose — compaction keeps the assembled request small; the rotating window is the backstop so a runaway background thread can never blow the KV budget.
- **Gemma interleaved attention accounting.** Gemma 4 interleaves **local sliding-window** layers (most layers; their KV is naturally bounded by the window) with a few **global** layers (full-context KV). So per-token KV bytes are **not** uniform across layers: the budget math (D4) sums `(num_sliding_layers × min(ctx, window) + num_global_layers × ctx) × kvBytesPerTokenPerLayer`. Treating every layer as global would massively over-estimate KV and under-provision K; treating every layer as local would under-estimate and risk OOM. The conformer exposes the layer split to the budget model.

### D4. `ConcurrencyBudget` — pure, RAM-is-the-ceiling math (Core, testable).

A pure value model (no MLX) that the conformer queries for K and the Hub queries for the cost surface:

```
struct KVCacheCost {            // pure
    var slidingLayers: Int
    var globalLayers: Int
    var slidingWindow: Int      // tokens
    var kvBytesPerTokenPerLayer: Double   // a function of head dim × kv-quant bits
    func kvBytes(forContext ctx: Int) -> Int64   // the interleaved-attention sum (D3)
}

struct ConcurrencyBudget {       // pure
    var unifiedMemoryBytes: Int64      // total (probed at the boundary; injected here)
    var weightBytes: Int64             // resident weights, read once
    var reservedBytes: Int64           // OS + app + graph activations headroom
    var kv: KVCacheCost
    /// How many concurrent streams fit at this context length, given KV-quant bits.
    func maxStreams(contextTokens: Int) -> Int       // floor((free - weights) / kvBytes(ctx)), clamped ≥1
    /// Estimated resident RAM at a given (streams, context) for the Hub cost surface.
    func estimatedRAM(streams: Int, contextTokens: Int) -> Int64
}
```

- **Foreground guarantee.** `maxStreams` is clamped to **≥ 1** so the foreground session always fits even if a chosen context is so large only one stream is affordable (then K=1 — background sessions wait, no OOM). This is the "RAM is the ceiling" honesty: growing context trades concurrency for length, visibly.
- Real memory probing (free unified bytes) happens at the GemmaRuntime boundary and is **injected** into the pure budget, so the math is unit-testable with fixed inputs (no Metal in `swift test`).

### D5. Context tuning: `maxContextTokens` + user-adjustable `agentContextTokens`, cost surfaced (integration fix C3).

- **`ModelDescriptor.maxContextTokens: Int`** is added (Core) — the model's architectural max (Gemma 4's large context). It is the clamp ceiling.
- **`agentContextTokens`** (persisted, Core `AppSettings`) is the user's chosen budget, **clamped to `maxContextTokens`**. It is set via three **presets** — **Balanced** (a comfortable mid value, the default), **Long**, **Max** (= the model max) — plus a **"compact long contexts (8-bit KV)"** toggle (`agentCompactKV`) that selects 8-bit KV so a longer context fits in the same RAM. A `agentContextPreset` enum persists the chosen preset (Balanced/Long/Max/custom).
- **Cost surfaced (house requirement — never silent OOM).** The Hub's AI page shows, derived from `ConcurrencyBudget.estimatedRAM` + `maxStreams`: estimated **RAM** at the chosen context and the resulting **concurrent-stream count** (e.g. "Max context · ~38 GB · 1 background session" vs "Balanced · ~24 GB · 3 background sessions"), and a relative **speed** note (longer context = slower per token). This is the explicit RAM/speed-cost-surfaced decision (cross-cutting decision: context growable AND user-adjustable with cost surfaced).
- **Global default + per-skill override.** A heavy skill (e.g. a long-document summarizer) may declare a larger context need; the effective budget for a session is `max(globalDefault, skillOverride)` clamped to the model max. The per-skill override value rides on the skill file (`ai-skills-as-files`); this slice only **reads** it through a small `SkillContextOverriding` seam, never owning the skill format.
- **The budget feeds compaction (the tie-in).** This slice ships the concrete `ContextBudgetProviding` (the protocol is owned by `ai-conversation-runtime`, C3): `maxContextTokens` resolves to the effective `agentContextTokens` (∩ model max ∩ per-skill override). conversation-runtime's `needsCompaction`/`plan` read this number — so growing the context slider directly raises the compaction trigger, and the two never disagree about "the budget."

### D6. The compact-KV toggle and the KV-quant selection.

`agentCompactKV` ON → the conformer uses **8-bit** KV (D3); OFF → bf16 (or the model's native KV precision). "Max" preset may **force** 8-bit (and surface that it did) because the model-max context at bf16 KV would not leave room for even one stream + headroom. 4-bit KV is reserved for the rotating-window background path where the longest threads run; it is not exposed as a user toggle (a feel-only internal choice for background streams), keeping the user surface to one comprehensible toggle.

### D7. `Subagent` — a fixed-pattern context-hygiene primitive (NOT concurrency, NOT dynamic spawning).

A subagent is **context hygiene**, not parallelism: it runs a bounded sub-task in a **fresh** `AgentConversation` (empty history, its own skill/prompt) and returns only a **summary** `AgentMessage` to the orchestrator, so the orchestrator's context stays lean (it never absorbs the sub-task's intermediate turns).

```
struct Subagent {                       // pure orchestration, Core
    let name: String                     // a named, fixed template (not model-invented)
    let systemPrompt: String
    let maxTurns: Int                    // bounded
}
struct SubagentResult { let summary: String; let sessionID: AgentSessionID }
```

- **Fixed-pattern, bounded.** The orchestrator invokes a **named** subagent (from a small registered set) with an input; the subagent runs ≤ `maxTurns` turns in its fresh session and returns a summary. There is **no** open-ended, model-decided recursive spawning (a small model handles that poorly — cross-cutting note). A subagent may itself be **a routed tool step** (`ai-tool-routing`), so "run subagent X" is a `ToolDescriptor`; the loop appends only the returned summary as a `.tool` message.
- **Runs on the batched runtime as just another session.** A subagent's fresh `AgentSessionID` can occupy a batch slot like any other stream — so subagents are *concurrency-cheap* (they ride the one weight read) while being *context-cheap* (their turns never pollute the orchestrator). It does not get its own weight read.
- Subagent results are summaries, never raw turn dumps — this is the whole point (orchestrator stays lean).

### D8. Errors map at the GemmaRuntime boundary; failure is per-stream and observable.

Vendor/MLX/OS errors (graph build, OOM at admit, a Metal abort) are mapped into `RuntimeError` **at the conformer boundary** — Core stays MLX-free, so only `RuntimeError` crosses out. Surfacing is bounded + non-blocking via `AIError.message(for:)`: a stream that fails emits a terminal error on **its** sub-stream only (its turn becomes `.failed` with a clean headline in conversation-runtime), and the **other batched streams keep running** (never a batch-wide abort, never a false "done" for the failed stream). An admit that cannot fit (OOM headroom) is **not** a failure of a running stream — the new session simply isn't admitted this step (it waits); `maxStreams ≥ 1` guarantees the foreground always fits. No `NSAlert`; raw MLX text goes only to logs / `AIPresentedError.details`.

### D9. Plug-in via the existing `ModelProvisioner` — no `ModelManager` API change.

`GemmaRuntime.makeModelManager`'s provisioner currently returns `GemmaMLXRuntime()`. It changes to return `BatchedGemmaMLXRuntime()` (which conforms to `LLMRuntime` *and* `BatchedLLMRuntime`). `ModelManager` is untouched — it stores the returned `LLMRuntime` resident exactly as today. Callers that need the batched entry point downcast `currentRuntime as? BatchedLLMRuntime` (the scheduler-driven background advancer does; the foreground `chat()` path does not need to — `chat()` is on the base protocol). This keeps Core's `ModelManager` MLX-free and the residency/lifecycle/registry behavior identical. **The metallib bundle landmine is unchanged** — `build-app.sh` still copies `*.bundle` into `Contents/Resources/`; the batched conformer hits the same Metal path, so no GPU use without the bundle (no regression introduced, none required).

### Rejected alternatives

- **Spawn K independent `generate()` tasks for concurrency.** Rejected — each re-reads the full weights from unified memory, so K tasks = K× the bandwidth on the *single* bottleneck; on a bandwidth-bound decode this is *slower* per token, not faster. Continuous batching (one read, K streams) is the only win.
- **A constant `maxConcurrentStreams`.** Rejected — KV grows with context and per stream, so a constant K either OOMs at long context or under-uses RAM at short context. K must be RAM-derived (`ConcurrencyBudget`).
- **Treat all attention layers as global for KV math (simpler).** Rejected — Gemma interleaves sliding-window (most) and global (few) layers; uniform-global over-estimates KV ~N× and needlessly throttles K. Per-layer-split math is required.
- **Expose raw KV-quant bits (bf16/8/4) as a user control.** Rejected — three precisions × context presets is an incomprehensible surface; one "compact long contexts (8-bit)" toggle is the user lever, 4-bit is an internal background choice.
- **Open-ended dynamic subagent spawning (model decides when/what to spawn, recursively).** Rejected — a small model orchestrates unbounded recursion poorly (runaway spawns, confused summaries); the fixed-pattern named-subagent + bounded-turns primitive is reliable and still gives the context-hygiene win.
- **Read `agentContextTokens` directly in conversation-runtime's compaction.** Rejected by integration fix C3 (would create a DAG back-edge to this slice). The injected `ContextBudgetProviding` (owned there) is the contract; this slice supplies the concrete provider.
- **A whole-new background runtime separate from the foreground one.** Rejected — two resident copies of the weights would blow the 48 GB budget. One batched runtime serves foreground slot 0 and background slots 1…K-1 over the same single weight read.

## Target split & verification (per component)

| Component | Target | Verification |
|---|---|---|
| `BatchedLLMRuntime` protocol (blueprint §3.6) | Core (MLX-free) | `swift build` / `swift test` (protocol + a stub conformer for tests) |
| `ConcurrencyBudget` + `KVCacheCost` (D4) | Core | `swift test` (K monotonic ↓ as context ↑; interleaved-layer KV sum; clamp ≥1; estimatedRAM) |
| `ModelDescriptor.maxContextTokens` (D5) | Core | `swift test` (registry decodes; clamp) |
| `ContextBudgetProviding` concrete provider (D5, C3) | Core | `swift test` (resolves effective budget = global ∩ model-max ∩ per-skill; injected into a conversation-runtime compaction test) |
| `agentContextTokens` / `agentContextPreset` / `agentCompactKV` persistence (D5/D6) | Core (`AppSettings`) | `swift test` (defaults Balanced, clamp, reset-to-defaults, legacy decode) |
| `Subagent` fixed-pattern primitive (D7) | Core | `swift test` (fresh-context isolation; only summary returned; bounded maxTurns) |
| `BatchedGemmaMLXRuntime` conformer: batched decode loop, KV-quant, prefix cache, rotating window (D2/D3) | GemmaRuntime (MLX-linked) | `xcodebuild` COMPILE-VERIFY ONLY; **real validation needs the user's stable-signed build** (TCC + Metal + live batching) |
| Provisioner returns the batched conformer (D9) | GemmaRuntime | `xcodebuild` compile-verify (the full product links Core + GemmaRuntime) |
| Hub AI-page cost surface (RAM/stream-count/speed) (D5) | Core/app UI | `xcodebuild` compile-verify; **user run-verify** the displayed numbers track the slider |

To compile-check this slice in isolation from sibling uncommitted files, use a throwaway `git worktree` + `swift build` — never the shared working tree's `.app` (ad-hoc signing breaks TCC; the user does real builds).

## Edge cases

- **Context so large only the foreground fits (K=1).** `maxStreams` clamps to ≥1; background sessions simply don't get a slot until context/RAM allows. The cost surface shows "0 background sessions" honestly.
- **A new session can't be admitted this step (OOM headroom).** It waits (stays in `runnableSessions`); running streams are untouched. Not a failure.
- **Prefix changes (a skill is enabled mid-session).** The prefix hash changes → the prefix KV cache invalidates and re-prefills once; subsequent turns reuse the new cached prefix.
- **A parked session is restored to foreground while batched.** Identity is `AgentSessionID` (stable across park/restore); it just moves to slot 0 — its KV cache is preserved if still resident, else re-prefilled.
- **A stream errors mid-batch.** Per-stream terminal error → that turn `.failed`; the rest of the batch continues (D8).
- **`agentContextTokens` lowered below the current thread's assembled size.** conversation-runtime compaction (reading the new lower budget via the provider) compacts on the next turn; the rotating-window KV is the GPU-side backstop.
- **Compact-KV toggled mid-session.** KV precision change applies to *new* prefill; existing quantized/unquantized cache for live streams is honored until they free their slot (no mid-stream re-quantize).
- **Subagent itself wants a heavy context.** Its per-skill override resolves independently in its fresh session; it occupies a batch slot under the same RAM ceiling.

## Risks / Trade-offs

- **Batched decode is the hardest MLX code in the project and is `xcodebuild`-compile-verify only.** Real correctness (no cross-stream KV bleed, correct masking/padding, prefill interleave) can only be validated in the user's stable-signed build. Mitigation: keep all *schedulable* and *budget* logic pure in Core (tested), and keep the conformer a thin, well-documented decode loop; the spec's scenarios are written so the user run-verify is unambiguous.
- **KV-quant quality loss.** 8-bit KV is near-lossless; 4-bit (background only) may degrade long-thread coherence. Mitigation: 4-bit is reserved for the rotating-window background path; foreground uses bf16 or 8-bit.
- **Memory probing accuracy.** Free-unified-bytes is an estimate; activations spike during prefill. Mitigation: `reservedBytes` headroom + clamp ≥1 + admit-or-wait (never admit into OOM).
- **Prefix-cache invalidation bugs leak stale context.** Mitigation: key strictly by prefix-text hash; a mismatch always re-prefills.
