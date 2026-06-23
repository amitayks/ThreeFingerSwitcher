## Context

Today `ModelManager` (`AI/ModelManager.swift`) owns exactly one resident runtime. `ModelDescriptor` (`AI/ModelRegistry.swift`) is `Identifiable, Equatable, Sendable` and carries `id`, `name`, size, integrity hash, download source, and `capabilities: Set<Modality>`. `StandardModelRegistry` lists a few Gemma descriptors; `ModelManager.resolveRuntime(for:)` selects one by required capabilities and loads it through the existing `ModelProvisioner` (real path) or `runtimeFactory` (dev-stub path). There is no notion of a *lane*, a *provider*, a *byte budget*, or *eviction to admit another model*.

The compute-media-fleet wave (addendum §C1) pins the fleet shapes this slice OWNS: `ModelRole`, `ModelProvider`, the extended `ModelDescriptor`, and the `ModelRegistry` protocol. The descriptor's `lane: ComputeLane?` field consumes `ComputeLane` from `ai-compute-tiers` (§A1) verbatim. The cloud gating (`fleetCloudEscalationEnabled`, under `fullPotentialEnabled`) comes from `ai-full-potential-toggle` (§D1). Sibling slices are authored concurrently, so this slice depends only on those **pinned contracts**, not on sibling files existing yet.

The hard physical fact this slice encodes: **48 GB unified is a shared budget.** Chat (~17 GB GPU) + ternary (~0.5 GB CPU) + a Q4 image model (~7 GB) + the live KV cache co-reside; a **video gen or an FP16 image model (~24 GB) cannot, and evicts chat.** Cloud members (Claude, GLM-5.2 / 753B) never fit and never try. That admission decision is pure math and must be correct before any weights move — so it lives in Core and is `swift test`-verified without real weights.

## Goals & Non-Goals

**Goals**

- Evolve `ModelDescriptor` to the §C1 shape (additively — every existing construction site keeps compiling) and add `ModelRole` / `ModelProvider` / the `ModelRegistry` protocol.
- A pure, unit-tested `ResidencyPlanner`: given descriptors + budget + free memory + a target, produce the resident set and the eviction list (video/FP16-image evicts chat; cloud never resident).
- Register the **cloud** members (Claude, GLM-5.2) as `.cloud` / `.cloudEscalation` — visible for selection, never resident, off until `fleetCloudEscalationEnabled`.
- Wire residency through the **existing** `ModelProvisioner` / `runtimeFactory` (no provisioner API change); a **fleet-of-one stays byte-for-byte today's behavior**.
- A Hub fleet-roster UX that discloses role / lane / provider / status / honest residency cost (including the evict-chat warning) inline.

**Non-Goals**

- The CPU lane runtime, `LaneRouting`, `TernaryCPURuntime` — owned by `ai-compute-tiers`; this slice only carries `lane` on the descriptor and plans the ternary model's co-residency.
- The media seam / tools / sink / concrete image+video backends — owned by `ai-media-runtime` and the two backend slices; this slice registers their descriptors and plans their residency only.
- The toggle storage and the master gate page — owned by `ai-full-potential-toggle`; this slice reads `fleetCloudEscalationEnabled`.
- Context-tuning sliders — owned by `ai-batched-runtime-and-context`; this slice only carries `maxContextTokens` on the descriptor.
- Any actual cloud API call / Claude-handoff mechanics — owned by `ai-claude-handoff`; this slice routes cloud members to that existing surface.

## Decisions

### D1. Extend the EXISTING `ModelDescriptor` additively — do not fork a `FleetDescriptor`.

The §C1 descriptor IS the evolution of today's descriptor, not a parallel type. Add `role: ModelRole`, `lane: ComputeLane?`, `provider: ModelProvider`, `residencyBytes: UInt64`, `maxContextTokens: Int?` to `ModelDescriptor`, with init defaults (`role: .chat`, `lane: .gpu`, `provider: .onDevice`, `maxContextTokens: nil`, `residencyBytes` derived from the existing size when unset) so the `.standard` entries and GemmaRuntime's `pipelineModel(for:)` keep compiling untouched. `residencyBytes` is the eviction-budget number (the on-GPU/on-CPU resident footprint), distinct from the on-disk download size already present.

- **Rationale:** A fleet-of-one is the existing single descriptor with defaults; a second type would force every caller (selection, lifecycle, Hub status) to branch. Additive fields keep one code path.
- **§C1 note:** §C1 sketches `ModelDescriptor` as `Codable`. Today's descriptor is `Equatable, Sendable, Identifiable` but **not** `Codable` (it is constructed in code, not persisted as JSON). We honor §C1's *field shape* verbatim but keep the descriptor non-`Codable` to match the existing registry (`capabilities: Set<Modality>` is the live capability set; §C1's `capabilities: Set<String>` is the sketch's stand-in for it). The persisted artifact is the **selected model id** (`ModelSelector`, already persisted) — not the descriptor — so no `Codable` is needed and the existing persistence is untouched.
- **Alternatives rejected:** (a) a separate `FleetDescriptor` wrapping `ModelDescriptor` — doubles the type surface and the Hub status logic; (b) making the descriptor `Codable` to match §C1 literally — would change the live capability type and gain nothing (descriptors are code-defined, the *id* is what persists).

### D2. `ModelRegistry` is a protocol; the standard fleet roster conforms — cloud members are roster-but-never-resident.

Add the §C1 `ModelRegistry` protocol (`descriptors()`, `resident()`, `ensureResident(_:)`). `FleetRoster` (evolving `StandardModelRegistry`) lists chat (GPU), ternary (CPU), image (Q4 + FP16 variants), and the two **cloud** members. `descriptors()` returns all (so selection + the Hub roster see cloud members); `resident()` returns only the on-device models currently loaded (cloud is `provider: .cloud` → never included); `ensureResident(id)` of a cloud member is a no-op for residency (it routes to escalation, see D5) and never touches the provisioner.

- **Rationale:** Cloud members must be *selectable and visible* (the roster, escalation routing) without ever being *resident* — the provider field cleanly separates "is in the fleet" from "occupies budget bytes." The protocol lets a fleet-of-one be a trivial conformer (one chat descriptor) identical to today.
- **Alternatives rejected:** a single concrete registry class — the protocol is one line and lets tests inject a scripted roster; excluding cloud members from `descriptors()` — then the Hub could not show them as available escalation targets.

### D3. Residency is a PURE PLANNER over `(descriptors, budgetBytes, freeBytes, target)` — eviction is data, not a side effect.

`ResidencyPlanner.plan(target:descriptors:budgetBytes:freeBytes:currentlyResident:)` returns a `ResidencyPlan { admit: [id], evict: [id], coResident: [id] }` — a pure value. The rules, encoded once and tested:

1. **Cloud target** (`provider: .cloud`) → empty admit/evict (cost 0, never resident); planning a cloud target is a residency no-op.
2. **Co-residency set:** chat (`.chat`, GPU) + ternary (`.ternaryChat`, CPU) + a **Q4** image model + the live KV reservation fit together when their `residencyBytes` sum + a KV reserve ≤ `budgetBytes` — admit the target alongside the rest.
3. **Eviction trigger:** if admitting the target (a `.video` model, or a `.image` model whose `residencyBytes` exceeds the FP16 threshold) would exceed `budgetBytes` with chat resident, the plan **evicts chat** (and any other GPU-lane occupant) — smallest-victim-first among GPU-lane models until the target fits, chat being the expected victim. The CPU-lane ternary (bandwidth-frugal, ~0.5 GB) is **not** evicted for a GPU gen (different lane, negligible bytes).
4. **Infeasible:** if the target cannot fit even after evicting every evictable on-device model, the plan reports infeasible → `ensureResident` throws `FleetError.cannotAdmit` (mapped through `AIError.message(for:)`, surfaced bounded + non-blocking).

`ModelManager` is the only place the plan is *applied* (evict → load); the planner itself never calls Metal or the provisioner. Free memory is an **injected probe** (a closure returning `UInt64`) so tests pass fixed values.

- **Rationale:** "What must be evicted to admit X" is exactly the kind of decision that must be correct before any irreversible memory move, and exactly the kind that is cheap to exhaustively unit-test if it is pure. Returning the plan as data (admit/evict/coResident) lets the Hub *preview* the cost ("selecting Video pauses chat") before the user commits.
- **Alternatives rejected:** computing eviction inside `ModelManager`'s load path with live `MTLDevice` queries — untestable by the agent, and entangles the honest-cost disclosure (which needs the plan *before* loading) with the side effect; a fixed "video always evicts chat" constant — wrong for the Q4-image co-resident case and for future budgets; making the planner async/Metal-aware — kills `swift test` verification.

### D4. Wire the planner through the EXISTING `ModelProvisioner` / `runtimeFactory` — fleet-of-one short-circuits.

`ModelManager.ensureResident(id)` (the registry method, implemented on the manager) runs `ResidencyPlanner.plan(...)`, evicts each `plan.evict` id via the **existing** evict path, then loads the target through the **existing** `ModelProvisioner` (real) or `runtimeFactory` (dev-stub) — no new provisioning seam. When the roster is a fleet-of-one (only the chat descriptor, no lane/cloud members) the plan is trivially `{admit:[chat], evict:[], coResident:[chat]}` and the load path is byte-for-byte today's lazy-load-and-keep-resident behavior.

- **Rationale:** The blueprint pins "reuse `ModelProvisioner`/`runtimeFactory`; a fleet-of-one MUST remain valid." Threading the planner *around* the existing load path (not through a new one) guarantees the single-model lifecycle, integrity-verify, residency, and per-model status requirements still hold unchanged.
- **Alternatives rejected:** a new `FleetProvisioner` — duplicates the download/verify/load/evict logic the manager already owns and risks regressing the metallib-bundle / TCC-stable-signing contracts.

### D5. Cloud members ride the Claude-handoff escalation surface, gated by `fleetCloudEscalationEnabled` (under `fullPotentialEnabled`).

A `.cloudEscalation` descriptor is never loaded; selecting one as a command's model routes the turn through the **existing** Claude-handoff escalation path (`ai-claude-handoff` §3.8: confirm-by-default, per-day budget cap, audited, fire-and-forget). The entire cloud tier is hidden from selection and never escalated to unless `fleetCloudEscalationEnabled` is true (and that flag is itself only meaningful when `fullPotentialEnabled` is on). GLM-5.2 is registered as a second cloud member alongside Claude — same `.cloud`/`.cloudEscalation` shape, its 753B/1M-ctx/MIT facts in `name`/`capabilities`, `residencyBytes: 0`.

- **Rationale:** "Cloud is escalation, not residency" is the addendum's load-bearing decision (§5.6, no silent spend). Reusing the Claude-handoff surface means no new audit/budget/confirm machinery — GLM-5.2 is just a second escalation destination.
- **Alternatives rejected:** treating GLM-5.2 as a giant local model with a degraded path — explicitly forbidden (§5.2, datacenter scale, does not fit 48 GB); a separate cloud-runtime seam — the handoff surface already is that seam.

### D6. The Hub fleet roster discloses cost in the same breath it offers selection — including the evict-chat warning and the cloud badge/budget.

The Hub AI page's model picker becomes a **fleet roster**: each member row shows role (Chat / Ternary / Image / Video / Cloud), lane (GPU / CPU / Cloud), provider, the existing per-model on-disk/resident status, and its **honest residency cost** (`residencyBytes` in GB). A member whose `ResidencyPlanner` plan would **evict chat** renders that warning inline ("selecting Video pauses the chat model; it reloads when generation finishes"), computed from the *plan*, not hard-coded. Cloud members show a **Cloud** badge + their escalation cost ($ / `mediaVideoBudgetPerDay`-style per-day cap) and are **disabled with an explanatory caption** until `fleetCloudEscalationEnabled`. A fleet-of-one renders exactly as today's single picker.

- **Rationale:** The wave's honest-surface ethos (§D1 disclosure UX) — no fans-screaming surprise, no surprise spend. Driving the warning from the plan keeps UI and math in sync.
- **Alternatives rejected:** a separate "advanced fleet" window — the Hub is the single config surface (configuration-hub invariant); a static cost label — would drift from the real budget/free-memory.

### D7. `FleetError` only for cases `RuntimeError` cannot carry; everything routes through the one translator.

Add a `FleetError: Error, Equatable, LocalizedError` with at most the cases the existing taxonomy cannot express: `.cannotAdmit(modelName:)` (residency infeasible even after eviction), `.cloudDisabled(modelName:)` (a cloud member selected while `fleetCloudEscalationEnabled` is off). Capability-mismatch, unavailable-hardware, download/integrity failures stay `RuntimeError`. Map any OS/probe error at the boundary into the taxonomy; surface via `AIError.message(for:)` → `AIPresentedError`, bounded + non-blocking, never `NSAlert`, never raw error text in a headline. A failed admission is an observable `.failed` for that selection, never a false "loaded."

- **Rationale:** Blueprint invariant — one taxonomy, one translator, mapped at the boundary. The two new cases are genuinely fleet-specific (eviction infeasibility, cloud-gated) and have no `RuntimeError` equivalent.
- **Alternatives rejected:** overloading `RuntimeError.unavailable(reason:)` for both — loses the structured model name the Hub needs to render a clean headline + Retry; raw-interpolating the eviction list into a string — banned in headlines.

## Per-component target-split & verification

| Component | Target | Verification |
|---|---|---|
| `ModelRole` / `ModelProvider` enums | Core (MLX-free) | `swift test` — round-trip, exhaustive cases |
| Extended `ModelDescriptor` (`role`/`lane`/`provider`/`residencyBytes`/`maxContextTokens`, additive init defaults) | Core (`AI/ModelRegistry.swift`) | `swift test` — fleet-of-one default-init equals today's descriptor; new fields set/read; `swift build` proves existing construction sites still compile |
| `ModelRegistry` protocol + `FleetRoster` (chat/ternary/image/cloud members) | Core (`AI/Fleet/`) | `swift test` — `descriptors()` includes cloud members; `resident()` never includes `.cloud`; a scripted roster conforms |
| `ResidencyPlanner` (pure plan: admit/evict/coResident) | Core (`AI/Fleet/ResidencyPlanner.swift`) | `swift test` — Q4 image co-resides with chat+ternary+KV under budget; video/FP16-image evicts chat; ternary (CPU) not evicted for a GPU gen; cloud target → empty plan; infeasible → `cannotAdmit`; injected free-memory probe with fixed values |
| `FleetError` taxonomy + `AIError.message(for:)` routing | Core | `swift test` — each case yields a clean headline via the single translator; no raw interpolation |
| `ModelManager` consuming registry + planner around the existing `ModelProvisioner`/`runtimeFactory` | Core (`AI/ModelManager.swift`) | `swift test` (with `StubLLMRuntime`) — `ensureResident` evicts the planned ids then loads the target; fleet-of-one path equals today's lazy-load; cloud `ensureResident` is a residency no-op |
| `fleetCloudEscalationEnabled` read seam (flag owned by `ai-full-potential-toggle`) | Core (read-only consumer) | `swift test` — off → cloud members not escalated / not selectable; on → escalation routes to handoff |
| Hub fleet-roster UX (role/lane/provider/status/cost, evict-chat warning, cloud badge + gated caption) | Native-linked (SwiftUI in app target) | `xcodebuild` compile-verify only; **user stable-signed build** verifies the live roster rendering, real per-model status, and the disclosure copy |
| GemmaRuntime `pipelineModel(for:)` consuming the new descriptor fields | GemmaRuntime (MLX-linked) | `xcodebuild` compile-verify only; the new fields must compile in the MLX path |
| Real residency / eviction with real weights (does Video actually evict chat + reload? does Q4 image truly co-reside under 48 GB? live free-memory probe) | User stable-signed build ONLY | The agent never builds/signs/installs the `.app` (ad-hoc signing breaks TCC; the `*.bundle` metallib copy must not regress). Live memory behavior, eviction/reload latency, and large-weight on-disk status are observable only here |
