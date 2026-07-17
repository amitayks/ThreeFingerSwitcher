> Decomposed for a workflow fan-out: §1–§4 are the pure-Core substrate (do first, all `swift test`), §5 is the native-linked ternary conformer (`xcodebuild` compile-verify only — real correctness needs the user's stable-signed build), §6 wires lane dispatch additively into the existing scheduler/batched seams, §7 gates on the master toggle, §8 verifies. The CPU lane (§5) requires the user's stable-signed build for real validation — the agent never builds/signs the `.app`.

## 1. `ComputeLane` + role→lane policy (pure Core)

- [x] 1.1 Add `ComputeLane { .gpu, .cpuTernary }` and `AgentWorkRole { foregroundGeneration, mediaDiffusion, toolRoute, classify, memoryRetrieval, parkedSubagent }` to `AI/Compute/ComputeLane.swift` (Core, MLX-free) — verbatim from addendum §A1, OWNED here. *Verify: `swift build`; `swift test` — both enums construct and round-trip `Codable`.*
- [x] 1.2 Add the `LaneRouting` protocol (§A1) + `DefaultLaneRouting` (D1): `foregroundGeneration`/`mediaDiffusion` → `.gpu`; `toolRoute`/`classify`/`memoryRetrieval`/`parkedSubagent` → `.cpuTernary`. Pure total function. *Verify: `swift test` — one assertion per `AgentWorkRole` case asserts the expected lane (exhaustive).*
- [x] 1.3 Add `LaneAffinity` (`{ sessionID: AgentSessionID, lane: ComputeLane }`, D4), constructed from a session's `AgentWorkRole` via `DefaultLaneRouting`. Consumes `AgentSessionID` verbatim from `ai-conversation-runtime` (do NOT redefine). *Verify: `swift test` — a `parkedSubagent` session yields `.cpuTernary`; a `foregroundGeneration` session yields `.gpu`.*

## 2. Cross-lane concurrency + residency budget (pure Core)

- [x] 2.1 Add `LaneResidencyBudget` (D3, Core, free-memory injected — no Metal): holds chat weight bytes (GPU, read once), KV bytes per GPU stream, and `ternaryResidencyBytes` (small, ~32× smaller weights); answers `ternaryCoResides(freeBytes:gpuStreams:contextTokens:) -> Bool`. *Verify: `swift test` — the ternary model co-resides with chat weights + GPU KV under a budget where a SECOND chat model would not fit; toggling `ternaryResidencyBytes` up/down flips the boundary as expected.*
- [x] 2.2 Add `LaneArbiter` (D3, Core, `now:` + free-memory injected): admits CPU-lane work CONCURRENTLY with GPU work, bounds CPU-lane concurrency on its own small cap, and enforces (1) a heavy GPU generation never waits on CPU work, (2) CPU bursts never starve/preempt the foreground GPU reply. *Verify: `swift test` — a GPU gen + a CPU burst both admitted in the same tick; the GPU gen is never deferred behind CPU work; the CPU cap rejects an over-cap CPU burst (it waits, not fails); deterministic for a fixed `now:`/free-mem.*
- [x] 2.3 Add a `StubTernaryRuntime` (Core, test-only) conforming to the EXISTING `LLMRuntime` (`generate`/`structured`/`capabilities`/`chat()`), scripting deterministic tokens + structured outcomes. *Verify: `swift test` — drives a `structured()` route turn + a short `generate`; tokens de-mux to the right `AgentSessionID`; no real weights.*

## 3. OFF-coercion gate decorator (pure Core)

- [x] 3.1 Add a `LaneRouting` decorator that, when `cpuLaneEnabled == false`, coerces every role's lane to `.gpu` (D6) so a one-lane / fleet-of-one build stays valid. Reads `cpuLaneEnabled`/`fullPotentialEnabled` (addendum §D1, owned by `ai-full-potential-toggle` — read, do NOT define). *Verify: `swift test` — with the flag off, every `AgentWorkRole` coerces to `.gpu`; with it on, `DefaultLaneRouting` mapping holds.*

## 4. Error mapping (pure Core)

- [x] 4.1 Map CPU-lane failures (load/prepare/decode) into the existing `RuntimeError` taxonomy at the conformer boundary; add a `ComputeError` LocalizedError ONLY if a lane-dispatch case genuinely cannot be carried by `RuntimeError` (D7 — prefer extending `RuntimeError`). Route through `AIError.message(for:)`. *Verify: `swift test` — a simulated CPU-lane failure produces a clean `AIPresentedError` headline (no raw text); a cancelled CPU-lane turn is NOT a failure.*
- [x] 4.2 Assert a failed CPU-lane step is an observable `.failed` for that turn with a clean headline, never a false "done." *Verify: `swift test` — a stub failure leaves the turn in `.failed` carrying the translated headline, never `.done`.*

## 5. `TernaryCPURuntime` conformer (native-linked — `xcodebuild` compile-verify ONLY)

> Native-linked. The agent NEVER builds/signs/installs the `.app` (ad-hoc signing breaks TCC grants). Real validation (live CPU/GPU concurrency, CPU per-token speed, no cross-lane bleed, RAM/heat) requires the **user's stable-signed build** — see §8.3. The metallib `*.bundle` → `Contents/Resources/` copy in `build-app.sh` must not regress.

- [x] 5.1 Add `TernaryCPURuntime` (GemmaRuntime/sibling framework) conforming to the EXISTING `LLMRuntime` — a SMALL ternary/BitNet-class model on the CPU lane (NOT a new protocol, D2). Map vendor/OS errors (bitnet.cpp-class, `Process`, file IO) into `RuntimeError` at the boundary. *Verify: `xcodebuild` compile.*
- [x] 5.2 Implement the short-bursts-only decode path (D5): `structured()` route turns, classify, memory-retrieval, and parked-subagent `generate`/`chat` — honest that per-token is slower than the GPU, so the long foreground reply is NEVER routed here. *Verify: `xcodebuild` compile; **user run-verify** structured bursts complete on CPU while the GPU streams the reply.*
- [x] 5.3 Confirm `capabilities` advertises `text` (and not the heavy GPU-only modalities); a vision/media role is never routed to the CPU lane. *Verify: `xcodebuild` compile; `swift test` against the stub — `lane(for: .mediaDiffusion) == .gpu` keeps media off the CPU lane.*

## 6. Lane-keyed wiring + additive lane-affinity dispatch (native-linked — `xcodebuild` compile-verify ONLY)

- [x] 6.1 Wire `TernaryCPURuntime` into the existing `ModelProvisioner`/`runtimeFactory` keyed by `ComputeLane` + the fleet descriptor (`role: .ternaryChat`, `lane: .cpuTernary`, addendum §C1 — consume, do NOT redefine) — NO `ModelManager` API change. *Verify: `xcodebuild` compile; **user run-verify** the ternary conformer is injected for `.cpuTernary`.*
- [x] 6.2 Read `ParkScheduler.runnableSessions(now:maxSlots:)`'s returned IDs and attach `LaneAffinity` via an ADDITIVE accessor (D4) — the pinned `runnableSessions` signature is UNCHANGED and the `ai-parked-sessions` files are NOT edited. *Verify: `xcodebuild` compile; **user run-verify** a `parkedSubagent` session carries `.cpuTernary` affinity.*
- [x] 6.3 In the dispatcher, route `.cpuTernary`-affined sessions to `TernaryCPURuntime` while the GPU `batchStep(...)` (§3.6) keeps serving `.gpu`-affined + foreground sessions — ADDITIVE, the `ai-batched-runtime-and-context` files are NOT edited. *Verify: `xcodebuild` compile; **user run-verify** a parked subagent advances on CPU CONCURRENTLY with a foreground GPU generation.*

## 7. Master-toggle gate (Core read + native install gate)

- [x] 7.1 Gate CPU-lane installation on `cpuLaneEnabled` under `fullPotentialEnabled` (D6, §D1 — read, owned by `ai-full-potential-toggle`): off → no `TernaryCPURuntime` installed, the OFF-coercion decorator (§3.1) routes all work to the GPU. *Verify: `swift test` for the decorator; **user run-verify** OFF installs no CPU lane and behaves exactly as today.* **(wire-compute-fleet: `makeModelManager(optedIn:fullPotentialEnabled:cpuLaneEnabled:)` now CALLS `LaneDispatch.installCPULane(...)` behind the live `fullPotentialEnabled && cpuLaneEnabled` gate — threaded from `AppSettings` via `AIRuntimeInjection.modelManagerFactory` + `main.swift`. A `.cpuTernary`-lane fleet descriptor resolves to the installed `TernaryCPURuntime` through the UNCHANGED provisioner seam keyed by `descriptor.lane`; OFF → nil → GPU lane alone, today's behavior.)**

## 8. Spec sync + verification

- [x] 8.1 Update `openspec/specs/on-device-ai-runtime/spec.md` with the MODIFIED two-lane requirements after implementation lands (AMEND the single-GPU assumption; do NOT touch the batched/parked slice specs). *Verify: `openspec validate ai-compute-tiers --strict`.*
- [x] 8.2 `swift build` + `swift test` green for all of §1–§4, §7 (the pure-Core majority). *Verify: CI / local `swift test`.*
- [ ] 8.3 **User's stable-signed build only:** verify live CPU/GPU concurrency (a parked subagent advances on CPU while the GPU streams a reply), CPU per-token speed is acceptable for short bursts, no cross-lane bleed, ternary co-residency fits the 48 GB budget, and CPU heat under sustained structured bursts is disclosed. *Verify: `INSTALL=1 ./scripts/build-app.sh`, then exercise a parked subagent during a foreground reply.*
