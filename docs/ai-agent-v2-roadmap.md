# AI Agent V2 — Implementation Roadmap

**Status:** integration-welded. Nine parallel slice architects each authored an OpenSpec change under
`openspec/changes/<slice>/`; this document is the integration architect's synthesis — the index, the
shared-contract summary, the sequenced implementation order, the cross-slice conflicts found and their
resolutions, and the open questions still needing a human decision.

The binding contract sketches live in **`docs/ai-agent-v2-blueprint.md`** (read it first). This roadmap
records how the nine real artifacts line up against that blueprint and the order in which
`/opsx:apply` should walk them.

All nine changes pass `openspec validate <change> --strict`.

---

## 1. The nine changes (index)

| # | Change | Capability | Wave | One-line role |
|---|---|---|---|---|
| 1 | [`ai-conversation-runtime`](../openspec/changes/ai-conversation-runtime/) | `on-device-ai-runtime` (delta) | 1 | The **type home**: `AgentMessage`/`AgentConversation`/`AgentSessionID`/`AgentTurn`, `LLMChatRequest` + default-flattened `chat()`, compaction. Seven slices import its types. |
| 2 | [`ai-tool-routing`](../openspec/changes/ai-tool-routing/) | `ai-command-tasks` (delta) | 2 | Inverts control: the **model** picks a tool via a `structured()` route turn; the bounded route→execute→continue loop reuses `TaskDispatcher`/`TaskReview` wholesale. Owns `ToolDescriptor`/`ToolRoute`/`ToolStepResult`/`WritePolicyTier`/`ToolRegistry`. |
| 3 | [`ai-batched-runtime-and-context`](../openspec/changes/ai-batched-runtime-and-context/) | `on-device-ai-runtime` + `tunable-settings` (delta) | 2 | The **MLX** slice: continuous-batching `BatchedLLMRuntime` (one weight read, K streams), KV-quant, RAM-derived concurrency budget, growable user-adjustable context with cost surfaced, the subagent primitive. |
| 4 | [`ai-skills-as-files`](../openspec/changes/ai-skills-as-files/) | `ai-command-catalog` + `ai-skill-index` (new) | 3 | Externalizes the 75-preset catalog into declarative `.skill.md` files; **owns** the shared `DocIndex`/`IndexedDoc`/`DocKind` retriever; idempotent identity-preserving catalog→files migration. |
| 5 | [`ai-agent-memory`](../openspec/changes/ai-agent-memory/) | `ai-memory` (new) | 3 | Two-tier on-disk memory (capped CORE + named subfiles) **over the shared `DocIndex`** (no second retriever); memory read/write tools carrying `WritePolicyTier`. |
| 6 | [`ai-parked-sessions`](../openspec/changes/ai-parked-sessions/) | `ai-parked-sessions` (new) | 3 | `ParkedSession`/`ParkState`/`ParkScheduler`, the durable conversation store, the notch home-zone rail + ambient needs-you glow (DockPreviewOverlay pattern), park/sleep/discard/evict lifecycle. |
| 7 | [`ai-background-autonomy`](../openspec/changes/ai-background-autonomy/) | `ai-background-autonomy` + `configuration-hub` (delta) | 4 | The **policy layer**: blast-radius tiers over `WritePolicyTier`, the user whitelist + effective-tier resolution, the append-only `AuditRecord`/`AuditLog`, the parked auto-vs-escalate gate. |
| 8 | [`ai-claude-handoff`](../openspec/changes/ai-claude-handoff/) | `ai-claude-handoff` (new) | 4 | `launch_claude` as a `.dangerous` `ToolContributor` reusing the open-claude-here `.command` launch; `ClaudeHandoffConfig`, fire-and-forget, rolling-24h budget cap, per-skill `auto` opt-in. |
| 9 | [`ai-conversational-canvas`](../openspec/changes/ai-conversational-canvas/) | `ai-command-band` (delta) | 4 | The **front end**: seed→float-up→multi-turn typed canvas, the canonical two-finger compass, the overscroll-park trigger; extends `AICommandExecutor.State` with `.awaitingSeed` + renders sibling states. |

---

## 2. Shared-contract summary (who owns what, who consumes it)

| Contract (blueprint §) | Owner | Concrete type / file | Consumers |
|---|---|---|---|
| Message / Conversation / session identity (§3.1) | `ai-conversation-runtime` | `AgentRole`/`AgentMessage`/`AgentSessionID`/`AgentConversation`/`AgentTurn` in `AI/Agent/AgentConversation.swift` | tool-routing, canvas, parked, memory, autonomy, batched, handoff |
| `LLMChatRequest` + `LLMRuntime.chat()` + `ContextBudgetProviding` (§3.2) | `ai-conversation-runtime` (request + injected budget seam); `ai-batched-runtime-and-context` (concrete provider + `ModelDescriptor.maxContextTokens`/`agentContextTokens`) | additive on `AI/LLMRuntime.swift`; default-flattened `chat()` | tool-routing, batched, canvas |
| Tool route schema (§3.3) | `ai-tool-routing` | `ToolDescriptor`/`ToolRoute`/`ToolStepResult`/`ToolStepStatus`/`WritePolicyTier`/`ToolRegistry`/`ApprovalGate`/`WritePolicyResolving` in `AI/Agent/ToolContracts.swift` | skills, memory, handoff, autonomy, canvas, conversation-runtime (placeholder hand-off) |
| Shared retrieval index (§3.4) | `ai-skills-as-files` (OWNS) | `DocIndex`/`IndexedDoc`/`DocKind` + `InMemoryDocIndex`; new `ai-skill-index` capability spec | `ai-agent-memory` (contributes `IndexedDoc`s into the **same merged snapshot**), tool-routing (candidate source mirrors `retrieve(query:limit:)`) |
| Parked scheduler (§3.5) | `ai-parked-sessions` | `ParkState`/`ParkedSession`/`ParkScheduler` + `SerialParkScheduler` | batched (`runnableSessions`/`didAdvance`), autonomy (`escalate`), canvas (restore + overscroll-park) |
| Batched runtime (§3.6) | `ai-batched-runtime-and-context` | `BatchedLLMRuntime` (Core protocol) + `BatchedGemmaMLXRuntime` (GemmaRuntime conformer) | parked (background advancer), conversation-runtime (real KV-reuse `chat()` override) |
| Write-policy + audit (§3.7) | `ai-background-autonomy` (resolution/whitelist/audit/escalation); `ai-tool-routing` (the bare `WritePolicyTier` enum, C1) | `Whitelist`/`BackgroundPolicyResolver`/`BackgroundGate`/`AuditRecord`/`AuditLog` | tool-routing (reads `writePolicy`), memory + handoff (set descriptor tier, emit records), parked (`escalate` target) |
| Claude handoff config (§3.8) | `ai-claude-handoff` | `ClaudeHandoffConfig`/`HandoffConfirmMode` | `ai-skills-as-files` (optional `claudeHandoff:` skill-file block carrier), tool-routing (`launch_claude` descriptor), autonomy (audit + tier) |

**Cross-cutting invariants honored by all nine:** Apple-Silicon M5/M4 only (no low-end fallbacks); one
error taxonomy (`RuntimeError`/`TaskError` + at most one `<Slice>Error` — the new ones are `SkillError`,
`MemoryError`, `ParkError`, `AuditError`, `HandoffError`, each justified) routed through the single
`AIError.message(for:)` translator, mapped at the layer boundary, surfaced bounded + non-blocking, never
`NSAlert.runModal`, never raw error text in a headline, a side effect that did not land is `.failed` never
a false Done; overlays are non-activating panels with synchronous `orderOut` teardown reusing the
DockPreviewOverlay pattern; the canonical two-finger compass (DOWN=affirm-only-at-top / UP=scroll &
overscroll-past-bottom=PARK / RIGHT=discard / LEFT=reserved / Enter=send; tool-step approval reuses
DOWN=approve / RIGHT=skip) with interpretation at the `AppCoordinator` consumer seam, recognizer
untouched.

---

## 3. Cross-slice consistency check

Verified the shared types match across every consuming slice, the dependency graph is acyclic, the gesture
verbs are uniform, and every MLX-linked piece is marked `xcodebuild` compile-verify-only. Findings below;
all are resolvable without re-planning a slice.

### Verified consistent

- **Message/Conversation/session** — `ai-conversation-runtime` writes §3.1 verbatim; tool-routing, parked,
  canvas, memory, autonomy, batched, handoff all consume `AgentMessage`/`AgentConversation`/`AgentSessionID`
  unchanged. `AgentSessionID` is the stable park/restore + batch-stream key everywhere.
- **`DocIndex` retrieval** — `ai-skills-as-files` owns it (new `ai-skill-index` spec); `ai-agent-memory`'s
  design and the index spec agree the index is **kind-agnostic** and the combined skills+memory TOC is one
  enumeration. No second retriever. Both reference the Files-band sync-model + async-cache bridge identically.
- **`WritePolicyTier` placement (C1)** — defined once with `ToolDescriptor` in `ai-tool-routing`; memory,
  skills, handoff, autonomy all *read/set* it, none redefine it. `ai-background-autonomy` owns resolution
  (descriptor ∩ whitelist), never widening `.dangerous`.
- **`ParkScheduler` is K-ready** — `runnableSessions(now:maxSlots:)` is the seam; `SerialParkScheduler`
  returns ≤1 now, the batched runtime's `ConcurrentParkScheduler` returns ≤K later with no protocol change.
  `now:` is an input everywhere (deterministic, DockHoverModel-style).
- **`AuditRecord`/`AuditLog`** — `ai-background-autonomy` writes §3.7 verbatim; memory and handoff emit
  records through narrow seams (e.g. `HandoffAuditing`) re-pointed at the real `AuditLog`. `record()` is
  non-blocking and never throws into the route loop in all three.
- **`ClaudeHandoffConfig`** — owned by `ai-claude-handoff`, carried as an optional skill-file block by
  `ai-skills-as-files`; exactly one definition. Descriptor stays `.dangerous`; `auto` is a per-skill
  effective-tier downgrade, never a descriptor change.
- **Gesture compass** — canvas D7, parked D4, and tool-routing's approval contract all use DOWN=affirm/approve
  (only at `canvasAtTop`), RIGHT=discard/skip, UP=scroll + overscroll-park, Enter=send. Recognizer untouched
  in all; interpretation at `AppCoordinator`.
- **Target split** — every MLX-linked component (the batched decode loop, KV-quant, prefix cache in
  `ai-batched-runtime-and-context`; the GemmaRuntime `chat()` override flagged by `ai-conversation-runtime`)
  is marked `xcodebuild` compile-verify-only + user run-verify. All other slices are MLX-free Core verified by
  `swift test`. Overlay panels (parked rail, canvas float-up) are `xcodebuild` compile-verify + user run-verify.
- **No dependency cycle** — the DAG is acyclic. The only apparent back-edge (conversation-runtime's compaction
  needing the batched runtime's context budget) is broken by the injected `ContextBudgetProviding` seam (C3):
  conversation-runtime owns the protocol + a default constant provider and lands first; batched supplies the
  concrete provider later.
- **Two `on-device-ai-runtime` deltas don't collide** — `ai-conversation-runtime` MODIFIES "Swappable model
  runtime abstraction" + ADDs conversation requirements; `ai-batched-runtime-and-context` ADDs disjoint
  batched/context requirements. Requirement names are disjoint, so the synced capability spec composes.

### Conflicts found + resolutions

1. **`ToolDescriptor` shape divergence (additive).** `ai-tool-routing`'s owned `ToolDescriptor` adds a
   `keywords: [String]` field (for its `KeywordToolCandidateSource`) beyond the blueprint §3.3 sketch.
   `ai-conversation-runtime` ships a placeholder `ToolDescriptor` "exactly per §3.3" (no `keywords`), and
   `ai-skills-as-files`/`ai-agent-memory` project to the §3.3 shape. **Resolution:** `ai-tool-routing`'s
   `ToolDescriptor` (with `keywords`) is canonical. The conversation-runtime placeholder is a deliberate
   subset that `ai-tool-routing` **replaces wholesale** when it takes ownership (the hand-off is "take
   ownership," not "freeze shape"); adding a field is non-breaking. Skills/memory must populate `keywords`
   when projecting (they already author `keywords` in front-matter, so the data exists). Low risk.

2. **Placeholder file vs owned file name.** `ai-conversation-runtime` introduces
   `AI/Agent/ToolPlaceholders.swift` (marked `// HAND-OFF: ai-tool-routing takes ownership`);
   `ai-tool-routing` lands the real types in `AI/Agent/ToolContracts.swift`. **Resolution:** when
   `ai-tool-routing` applies, it must **delete `ToolPlaceholders.swift`** and move the types to
   `ToolContracts.swift` (not leave both — duplicate type definitions would not compile). Call this out in
   the tool-routing apply step. Mechanical.

3. **Two slices assumed siblings were "not on disk."** `ai-tool-routing` (Q1) wrote a stand-in
   `ConversationSeam` (`ConversationContext`/`ChatStreaming`) and `ai-claude-handoff` wrote
   `HandoffAuditing`/`HandoffEscalating` no-op seams because they planned before the owner slices were
   committed. **Resolution:** all owner slices ARE now on disk with final types. When applying in wave order
   (below), tool-routing binds directly to `AgentMessage`/`chat()` and **deletes `ConversationSeam`**; handoff
   re-points its seams at the real `AuditLog`/`ParkScheduler.escalate`. The blueprint §3.1/§3.5/§3.7 sketches
   are final enough to bind (confirmed — the committed types match the sketches). No shape renegotiation
   needed; only the stand-in seams are removed on bind.

4. **`InMemoryDocIndex` must accept externally-contributed docs.** `ai-skills-as-files` owns
   `InMemoryDocIndex`; `ai-agent-memory` contributes its `IndexedDoc`s into the **same merged snapshot**.
   Both flagged the risk that skills might build the index skills-private. **Resolution:** the `ai-skill-index`
   spec already requires the index be "kind-agnostic … a combined skills-and-memory table of contents is one
   enumeration." `InMemoryDocIndex` must therefore take its snapshot as a **merge of N contributors'
   `[IndexedDoc]`** (skills store ∪ memory store), not a skills-internal list. Bind memory's
   `MemoryStore.indexedDocs()` into the same snapshot builder. This is the documented contract; flag it in the
   skills apply step so the index is built merge-shaped from day one.

5. **Missing `.openspec.yaml` in three changes (now fixed).** `ai-background-autonomy`, `ai-claude-handoff`,
   and `ai-conversational-canvas` were missing the `.openspec.yaml` the blueprint §7 authoring rule requires
   (the other six had it). **Resolution:** created all three (`schema: spec-driven`, `created: 2026-06-22`)
   to match the existing six. Done as part of this integration pass.

6. **`canvasAtBottom` ownership.** `ai-conversational-canvas` (open Q) asked whether it or `ai-parked-sessions`
   owns the `canvasAtBottom` reporter. **Resolution (settled):** the **canvas** owns the `CanvasAtBottomKey`
   reporter + the `executor.canvasAtBottom` field (symmetric to the existing `canvasAtTop`); **parked-sessions**
   owns the pure `OverscrollPark.shouldPark(dy:canvasAtBottom:overscrollThreshold:)` decision it feeds.
   Both designs already describe exactly this split — no code conflict, just confirm the boundary at apply time.

---

## 4. Implementation order (topological over the dependency DAG)

Apply in this order. Within a wave, slices are independent and may be applied in any sub-order; the wave
boundary is the hard sequencing constraint (a later wave assumes earlier-wave types exist on disk).

1. **`ai-conversation-runtime`** — Wave 1, the type home. Everything imports its `AgentMessage`/
   `AgentConversation`/`AgentSessionID`/`AgentTurn` + `LLMChatRequest`/`chat()`. Ships the placeholder tool
   types + the injected `ContextBudgetProviding` so it builds standalone before Waves 2–4.
2. **`ai-tool-routing`** — Wave 2. Owns the route schema + loop + `ToolRegistry` + `WritePolicyTier`. On
   apply: delete the conversation-runtime placeholder `ToolPlaceholders.swift` + its own `ConversationSeam`
   stand-in, bind to the real types (conflicts 2, 3).
3. **`ai-batched-runtime-and-context`** — Wave 2 (parallel with tool-routing; depends only on
   conversation-runtime's `LLMChatRequest`). Supplies the concrete `ContextBudgetProviding` + `BatchedLLMRuntime`;
   consumes `ParkScheduler.runnableSessions` (a stub until Wave 3's scheduler lands — its pure budget/scheduling
   logic is tested against a stub, the MLX decode loop is compile-verify-only).
4. **`ai-skills-as-files`** — Wave 3. Owns `DocIndex`; build `InMemoryDocIndex` as a merge-of-contributors
   snapshot (conflict 4). Depends on tool-routing's `ToolDescriptor`.
5. **`ai-agent-memory`** — Wave 3. Consumes the `DocIndex` contract (contributes `IndexedDoc`s into the merged
   snapshot); sets memory descriptor tiers (effective `.auto` resolved in Wave 4).
6. **`ai-parked-sessions`** — Wave 3. Owns `ParkScheduler`/`ParkedSession`/`ParkState` + the durable store +
   the notch rail. Provides the scheduler the Wave-2 batched runtime fills (the batched slice re-binds its
   scheduler stub to `SerialParkScheduler` here).
7. **`ai-background-autonomy`** — Wave 4. Ships the production `WritePolicyResolving` conformer (replaces
   tool-routing's `DescriptorWritePolicy` default) + whitelist + `AuditLog` + `BackgroundGate`; calls
   `ParkScheduler.escalate`.
8. **`ai-claude-handoff`** — Wave 4. Registers the `launch_claude` `ToolContributor`; re-points
   `HandoffAuditing`/`HandoffEscalating` at the real `AuditLog`/`ParkScheduler.escalate` (conflict 3).
9. **`ai-conversational-canvas`** — Wave 4, last. Wires the front end over all earlier waves: renders the
   route-loop state, the multi-turn thread, the compass, the overscroll-park trigger into the parked store.

---

## 5. Open questions still needing a human decision

These are tuning values or small policy choices the architects flagged that are not derivable on paper and
do **not** block applying the first change. Resolve during run-verify or at the relevant wave.

- **Tuning constants (run-verify, M5 stable-signed build):** `keepRecentTurns` + compaction margin %
  (conversation-runtime); `maxToolSteps` default 8 (tool-routing); Gemma 4 real `maxContextTokens`,
  Balanced/Long preset token values, `kvBytesPerTokenPerLayer`, sliding-window size + sliding/global layer
  split (batched — ground in the actual Gemma 4 `config.json` at code time); `MemoryCap` defaults (~8 KB / ~60
  facts); `agentMaxParkedSessions`, `agentParkIdleTimeout`, `overscrollThreshold` (must sit above
  `canvasResolveThreshold`); the needs-you glow radius/period/accent (parked — make-or-break, feel-only);
  audit retention cap (500 vs a time window).
- **Conversation title derivation:** the field is on `AgentConversation` (owned by conversation-runtime), but
  whether a smart title comes from a model call or the first user turn is left to canvas/parked — confirm who
  computes it.
- **Descriptor identity for configured tasks (tool-routing Q2):** encode bound config in the descriptor name
  (`save_to_project:<project>`) vs a side table. Proposed name-encoding; confirm.
- **Skill `claudeHandoff:` front-matter spelling (handoff Q4 / skills):** the two slices must agree on the
  exact block spelling (`{ auto: true, maxPerDay: 3, dir: … }` vs full `ClaudeHandoffConfig` field names) so
  the parse maps cleanly. Owner: `ai-skills-as-files`; type: `ai-claude-handoff`.
- **`PolicyTarget` threading (autonomy Q1):** confirm `ai-tool-routing` passes the extracted `PolicyTarget`
  into the additive `effectiveTier(for:target:)` overload at the call site (no protocol change). Without it the
  whitelist can only act on the descriptor-only fast path and never lowers `.confirm`.
- **Background compaction trigger:** whether a parked session's compaction runs in the background (batched) or
  only at foreground turn time — the pure `plan()`/`summarize()` split supports both; confirm trigger ownership
  with parked/batched.
- **Front-matter parser dependency:** hand-rolled YAML subset vs adding a YAML parser to Core (skills) — both
  MLX-free-legal; defaulted to the documented subset, confirm.
- **Whitelist command-pattern grain (autonomy Q3):** `argv[0]`/tool-name anchored glob only (proposed) vs full
  shell-command-line patterns (rejected as too sharp). Confirm `argv[0]`-only for v1.
- **`nextRunAt` setter (parked Q):** who sets a future scheduled continuation (a skill? a tool? the user?) is
  not defined in any one slice — needs a cross-slice owner.
- **Discarded-session audit retention (parked/autonomy):** does a discarded conversation's append-only audit
  trail outlive the removed conversation? (Append-only argues yes.)

---

## 6. MLX / build note (binding)

**`ai-batched-runtime-and-context` requires the user's stable-signed build to validate.** Its pure pieces
(`BatchedLLMRuntime` protocol, `ConcurrencyBudget`/`KVCacheCost` math, `ModelDescriptor.maxContextTokens`,
the `ContextBudgetProviding` provider, the `Subagent` primitive, settings persistence) verify under
`swift test`. But the **batched decode loop, KV-quant, prefix cache, and rotating-window** live in the
MLX-linked `BatchedGemmaMLXRuntime` (GemmaRuntime target) and are **`xcodebuild` compile-verify ONLY** for an
agent. Real correctness — no cross-stream KV bleed, correct padding/masking, prefill interleave, live
batching across foreground + parked slots, the displayed RAM/stream-count/speed cost surface tracking the
slider — can only be confirmed in the **user's stable-signed build** (TCC + Metal + live multi-stream). The
same applies to the deferred real Gemma chat-template `chat()` override flagged by `ai-conversation-runtime`,
and to every overlay panel (the parked notch rail/glow, the canvas float-up/key-main flip). An agent
**never** builds/signs/installs the `.app` — ad-hoc signing breaks TCC grants. The metallib bundle landmine
(`build-app.sh` copies `*.bundle` into `Contents/Resources/`) is unchanged and must not regress.

---

## 7. Readiness

**Ready for implementation.** All nine changes validate `--strict`, the shared contracts match across every
consumer, the dependency DAG is acyclic, the gesture verbs are uniform, and every MLX-linked piece is marked
compile-verify-only. The conflicts found (§3) are mechanical bind-time actions (delete the two stand-in seams
+ the placeholder file, build the index merge-shaped, populate `keywords` on projection) folded into the
apply order (§4), plus the three `.openspec.yaml` files created during this pass. `/opsx:apply` can start on
`ai-conversation-runtime` (Wave 1) without rework.
