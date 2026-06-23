# AI Agent V2 — Addendum: Compute Tiers · Generative Media · Model Fleet

**Status:** binding on the SIX new slice architects (`ai-compute-tiers`, `ai-media-runtime`,
`ai-local-image-generation`, `ai-video-animation-generation`, `ai-model-fleet`,
`ai-full-potential-toggle`). This EXTENDS `docs/ai-agent-v2-blueprint.md` — read that FIRST. Every
convention there (naming, target-split, error taxonomy, gesture compass, reuse-don't-reinvent, OpenSpec
authoring rules §7) still binds. This addendum only pins the NEW shared types these six slices add, and
the decisions that resolve how they weld onto the existing nine.

This is the second evolution wave: from a single-GPU, single-model, text-only agent into a
**two-lane (GPU+CPU), multi-model, media-generating** companion — still Apple-Silicon M5/M4 only, still
behind one master opt-in.

---

## 0. What this wave EVOLVES (never forks)

| Existing seam / slice | V2.5 role |
|---|---|
| `LLMRuntime` (`AI/LLMRuntime.swift`) | UNCHANGED as the text seam. The CPU ternary model is **another `LLMRuntime` conformer**, selected by lane, not a new protocol. |
| `ai-batched-runtime-and-context` (§3.6 `BatchedLLMRuntime`) | Stays the **GPU lane**. `ai-compute-tiers` adds the CPU lane beside it + cross-lane budget; it AMENDS the GPU-only assumption, it does not rewrite the batched slice. |
| `ParkScheduler` (§3.5) | Gains an optional **lane-affinity hint** so a parked subagent can be dispatched to the CPU lane CONCURRENTLY with a foreground GPU generation. Additive; `runnableSessions(now:maxSlots:)` signature unchanged. |
| `ToolRegistry` / `ToolDescriptor` / route loop (§3.3) | Media generation is a **tool**: `generate_image` / `generate_video` are `ToolDescriptor`s with a `WritePolicyTier`; `MediaGenSink` executes via the existing route→execute→continue loop. No new control flow. |
| `WritePolicyTier` / `AuditLog` (§3.7) | Media writes + cloud-video escalation ride the SAME tiers + audit. Image gen = `.confirm`; cloud video = `.dangerous` + budget cap (mirrors Claude handoff §3.8). |
| `ModelManager` / `ModelProvisioner` (`AI/ModelManager.swift`) | `ai-model-fleet` evolves it from one-resident-runtime to a **registry of descriptors with residency/eviction**. The provisioner seam is reused; a fleet-of-one is today's behavior. |
| `files-band` (`Files/`, `Overlay/FilesBandView.swift`) | Generated assets land as **Files-band entries** (the gallery). Reuse, do not build a new browser. |
| `ai-claude-handoff` (§3.8) gating | The **template** for cloud-media escalation: confirm-by-default, per-day budget cap, audited, fire-and-forget. |
| `DockPreviewOverlay` pattern | The media canvas preview/player + any reveal surface reuse it (non-activating, synchronous `orderOut`). |

---

## 1. Naming (binding, extends blueprint §1)

- **New change dirs / slice names (verbatim):** `ai-compute-tiers`, `ai-media-runtime`,
  `ai-local-image-generation`, `ai-video-animation-generation`, `ai-model-fleet`,
  `ai-full-potential-toggle`.
- **New capability spec:** `ai-generative-media` (owned by `ai-media-runtime`; the two backend slices
  write deltas against it). Compute/fleet/toggle slices write deltas against existing capabilities
  (`on-device-ai-runtime`, `configuration-hub`, `tunable-settings`).
- **New Swift types:** PascalCase, no `V2` suffix. New homes under
  `Sources/ThreeFingerSwitcher/AI/Compute/`, `AI/Media/`, `AI/Fleet/` (Core, MLX-free for seams + value
  types + policy logic). Native-linked backends live in the `GemmaRuntime` target or a sibling
  framework.
- **New error enums (one per domain, only if `RuntimeError`/`TaskError` cannot carry it):**
  `MediaError`, `FleetError`. A `ComputeError` only if lane dispatch genuinely needs its own case;
  prefer extending `RuntimeError`. All route through `AIError.message(for:)` → `AIPresentedError`.
  Map vendor/OS errors (mflux, LTXV/ComfyUI, bitnet.cpp, `Process`, `NSURLError`) at the layer boundary.
- **New persisted keys (camelCase, agent-scoped):** `fullPotentialEnabled`, `cpuLaneEnabled`,
  `mediaGenEnabled`, `fleetCloudEscalationEnabled`, `mediaVideoBudgetPerDay`, `imageModelID`,
  `videoProvider`.

---

## 2. Target-split & verification (binding, extends blueprint §2)

- **MLX-free Core (`swift build` + `swift test`):** `ComputeLane` + the role→lane policy; the
  `MediaRuntime` PROTOCOL + all media value types; `MediaGenSink` routing; `ModelRegistry` +
  `ModelDescriptor` value types + residency/eviction MATH; `fullPotentialEnabled` + gating logic;
  `MediaError`/`FleetError`. **This is the majority of every new slice.** A `StubMediaRuntime` +
  `StubTernaryRuntime` make it all test-verified without real weights.
- **Native-linked (`xcodebuild` COMPILE-VERIFY ONLY for an agent; real correctness needs the user's
  stable-signed build):** the bitnet.cpp-class **ternary CPU runtime**; the **mflux/FLUX image
  runtime**; the **LTXV video runtime**; real residency/eviction with real weights; the canvas media
  **player overlay**. Each new `design.md` MUST state per-component which target it lives in and how it
  is verified. Agents NEVER build/sign/install the `.app` (ad-hoc signing breaks TCC; the
  `*.bundle` metallib copy in `build-app.sh` must not regress).

---

## 3. SHARED CONTRACTS (canonical sketches — binding)

Sketches, not final code. The OWNER slice writes the real type; CONSUMERS import it as written.

### §A1. Compute lane — OWNER: `ai-compute-tiers`

```swift
// Core. Which physical lane a runtime/work-unit uses. The GPU does heavy generation + diffusion;
// the CPU ternary lane does short/frequent/structured work (routing, classify, memory-index,
// parked subagents) — concurrently, because ternary weights are bandwidth-frugal.
public enum ComputeLane: String, Codable, Sendable { case gpu, cpuTernary }

// The pure role→lane policy. Heavy generation → .gpu; router turn / classification /
// memory retrieval / parked subagent advance → .cpuTernary. Pure + testable.
public protocol LaneRouting: Sendable {
    func lane(for role: AgentWorkRole) -> ComputeLane
}
public enum AgentWorkRole: String, Codable, Sendable {
    case foregroundGeneration   // the main reply → GPU
    case mediaDiffusion         // image/video gen → GPU (evicts chat; see §C1)
    case toolRoute              // structured() route turn → CPU ternary
    case classify               // cheap decisions (should-park / needs-you / which-skill) → CPU ternary
    case memoryRetrieval        // index/TOC retrieval → CPU ternary
    case parkedSubagent         // background advance of a parked session → CPU ternary
}
```

- The **CPU ternary model is an `LLMRuntime` conformer** (`TernaryCPURuntime`), NOT a new protocol. It
  carries a SMALL ternary/BitNet-class model. Selected by lane via the registry (§C1).
- `ai-compute-tiers` MUST justify, with the measured M5 facts (prefill up to ~4× on the GPU neural
  accelerators; token-gen bandwidth-bound at ~153 GB/s; ternary = ~32× smaller, bandwidth-frugal), why
  the CPU lane breaks the single-GPU serialization for light work — and be HONEST that CPU per-token is
  slower, so the lane is for short structured bursts, never the long reply.
- It AMENDS `ai-batched-runtime-and-context` (the GPU lane) and adds the lane-affinity hint consumed by
  `ParkScheduler` — as MODIFIED requirements on `on-device-ai-runtime`, not by editing the batched
  slice's files.

### §B1. Generative-media seam — OWNER: `ai-media-runtime`

```swift
// Core. A SECOND runtime seam, parallel to LLMRuntime — NOT a token stream. A long async job
// with step-progress that ends in bytes/a file.
public enum MediaKind: String, Codable, Sendable { case image, video }

public struct MediaParameters: Codable, Equatable, Sendable {
    public var size: MediaSize          // width × height
    public var steps: Int               // diffusion steps
    public var seedNumber: UInt64?      // RNG seed for reproducibility
    public var guidance: Double?
    public var durationMs: Int?         // video only
}

public struct MediaRequest: Sendable {
    public var prompt: String
    public var seed: Data?              // optional SEED IMAGE (PNG) for img2img / img2video — the
                                        // screen-region / clipboard capture becomes the first frame
    public var kind: MediaKind
    public var parameters: MediaParameters
}

public enum MediaProgress: Sendable {
    case step(index: Int, total: Int, preview: Data?)   // streamed diffusion progress + optional preview
    case finished(MediaAsset)
}

public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var url: URL                 // the written file (becomes a Files-band entry)
    public var kind: MediaKind
    public var width: Int
    public var height: Int
    public var durationMs: Int?
}

public protocol MediaRuntime: Sendable {
    var capabilities: Set<MediaKind> { get }
    func generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error>
}
```

- `generate_image` and `generate_video` are **`ToolDescriptor`s** (§3.3) registered in the
  `ToolRegistry`; `MediaGenSink` is the side-effecting executor invoked by the route loop. Write-policy
  tiers: **image `.confirm`**, **cloud video `.dangerous` + budget-capped** (mirrors handoff §3.8).
- Result lands as a **Files-band asset** (the gallery) AND a **canvas preview/player**; swipe-DOWN
  extracts (save / paste / set-as), per the canonical compass. Generation is **slow → parks** via
  `ParkScheduler`; the notch glows on completion / on `needsYou`.
- `MediaError` taxonomy, mapped at the boundary, surfaced bounded + non-blocking (never `NSAlert`, never
  raw error in a headline). `ai-media-runtime` OWNS the seam + tools + sink + Files/canvas output; it
  does NOT own the concrete backends.

### §B2. Image backend (in scope NOW) — OWNER: `ai-local-image-generation`
- A concrete `MediaRuntime` for **local image** via mflux/FLUX-class MLX (native-linked,
  compile-verify-only; descriptor + residency math + a stub are `swift test`-verified). Quant variants
  (Q4 ~7 GB → FP16 ~24 GB). M5 diffusion is compute-bound → neural-accelerator sweet spot (~3.8× vs M4).
  img2img/inpaint from the seed. Residency vs Gemma is DECIDED by the fleet (§C1) and consumed here.

### §B3. Video/animation backend (frontier + escalation) — OWNER: `ai-video-animation-generation`
- **Honest default = CLOUD escalation** (LTX Studio API / hosted), gated EXACTLY like Claude handoff
  (§3.8): confirm-by-default, per-day budget/rate cap, audited, fire-and-forget with progress. **Local
  LTXV** is a FRONTIER option behind the full-potential toggle (ComfyUI/MPS, 35 GB+, minutes/clip — NOT
  in-process MLX; document the cost). img2video from the seed. Build the seam so a local LTXV backend
  drops into the SAME `MediaRuntime` later, exactly as `LLMRuntime` lets Gemma be swapped.

### §C1. Model fleet — OWNER: `ai-model-fleet`

```swift
// Core. Evolves ModelManager from one-resident-runtime to a registry with residency/eviction.
public enum ModelRole: String, Codable, Sendable {
    case chat              // Gemma on the GPU lane
    case ternaryChat       // the small CPU-lane model
    case image, video      // generative-media backends
    case cloudEscalation   // Claude, GLM-5.2 — NOT resident locally
}

public struct ModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var role: ModelRole
    public var lane: ComputeLane?          // nil for cloud
    public var provider: ModelProvider     // .onDevice / .cloud
    public var residencyBytes: UInt64      // for the eviction budget (0 for cloud)
    public var maxContextTokens: Int?      // chat/ternary only
    public var capabilities: Set<String>   // text/vision/image/video tags
}
public enum ModelProvider: String, Codable, Sendable { case onDevice, cloud }

public protocol ModelRegistry: Sendable {
    func descriptors() -> [ModelDescriptor]
    func resident() -> [ModelDescriptor]
    func ensureResident(_ id: String) throws            // may EVICT under the 48GB budget
}
```

- Residency math is pure/testable: chat (GPU) + ternary (CPU) + image (Q4) + KV can co-reside; a
  **video gen or FP16 image EVICTS chat** (the companion goes quiet while it paints — document it).
- **Claude and GLM-5.2 are `provider: .cloud`, `role: .cloudEscalation`** — never resident; they ride
  the handoff/escalation paths. GLM-5.2 (753B MoE / 1M ctx / MIT) does NOT fit 48 GB — local is not an
  option; it is a cloud fleet member only.
- Reuse `ModelProvisioner`/`runtimeFactory`. A fleet-of-one MUST remain valid (today's behavior).

### §D1. The master gate — OWNER: `ai-full-potential-toggle`

```swift
// Core (AppSettings + gating logic). Default OFF → V2 ships calm; ON lights up the fleet.
// master:
var fullPotentialEnabled: Bool            // default false
// sub-capability flags, each gated under the master:
var cpuLaneEnabled: Bool                  // ai-compute-tiers
var batchedRuntimeEnabled: Bool           // ai-batched-runtime-and-context (existing heavy slice)
var mediaGenEnabled: Bool                 // ai-media-runtime + backends
var backgroundAutonomyEnabled: Bool       // ai-background-autonomy (existing heavy slice)
var fleetCloudEscalationEnabled: Bool     // ai-model-fleet cloud members (Claude / GLM-5.2)
```

- The gating logic is Core + `swift test`-verified. Each heavy slice CHECKS its flag before activating.
- **Disclosure UX (the project's honest-surface ethos, applied to capability cost):** each sub-toggle
  states its RAM / heat / latency / $-cost in the same breath it offers the capability — no hidden
  fans-screaming surprise. Progressive enablement; the master gate is one Hub page.

---

## 4. Dependency weld onto the existing nine (binding)

```
existing Wave 1–2 (conversation-runtime, tool-routing, batched-runtime) land FIRST
        │
ai-compute-tiers ──amends──> batched-runtime (GPU lane) + parked-sessions (lane affinity)
        │   adds the CPU ternary LLMRuntime conformer + role→lane policy
        │
ai-model-fleet ──evolves──> ModelManager (registry/residency); consumes ComputeLane;
        │                    registers cloud members (Claude, GLM-5.2)
        │
ai-media-runtime ──new seam──> registers generate_image/video tools in ToolRegistry;
        │                       output → Files band; parks via ParkScheduler
        ├──> ai-local-image-generation  (concrete image MediaRuntime; in scope NOW)
        └──> ai-video-animation-generation (cloud escalation default; local LTXV frontier)
        │
ai-full-potential-toggle ──gates──> compute-tiers, batched-runtime, background-autonomy,
                                     media (runtime+backends), fleet cloud escalation
```

**Implementation order (after the existing nine's waves):**
1. `ai-compute-tiers` (CPU lane beside the GPU batched runtime).
2. `ai-model-fleet` (registry/residency — needs the lane concept).
3. `ai-media-runtime` (the seam + tools + sink + output).
4. `ai-local-image-generation`, `ai-video-animation-generation` (backends, parallel; depend on the seam + fleet).
5. `ai-full-potential-toggle` (last — gates everything new + the existing heavy slices).

Architects plan in PARALLEL now; the order above is the *implementation* sequence so a later slice may
assume an earlier one's types exist.

---

## 5. Cross-cutting decisions (adopted — every new architect honors)

1. **Hardware floor is M5 (M4 min). No regressions, no degraded paths.** These features exist BECAUSE
   the hardware serves them. Cite the measured M5 facts where relevant.
2. **GLM-5.2 is cloud-only** (753B MoE / 1M ctx / MIT — datacenter scale). The local CPU model is a
   **small ternary/BitNet-class** model. Do not propose GLM-5.2 as a resident local runtime.
3. **Two lanes, one process:** GPU = heavy craftsman (chat reply, diffusion); CPU ternary = fast clerks
   (route, classify, remember, parked subagents). Ternary is bandwidth-frugal → low contention on the
   shared 153 GB/s bus. CPU per-token is slower → short structured work only.
4. **Media is a tool, parked because it's slow, gated by write-policy, audited.** Image `.confirm`;
   cloud video `.dangerous` + budget cap (the Claude-handoff pattern). Output is a Files-band asset.
5. **A heavy gen EVICTS chat** under the 48 GB budget — state it honestly in the fleet + media specs;
   surface "the assistant is busy painting" rather than pretend co-residency.
6. **Default OFF.** V2 ships calm; the master toggle is the user's deliberate "release full potential."
   Every sub-capability discloses its cost. No silent escalation, no surprise spend (cloud members are
   off until `fleetCloudEscalationEnabled`).
7. **All blueprint invariants still bind:** one error taxonomy + one translator, mapped at the
   boundary, bounded + non-blocking, never `NSAlert`/raw-error-in-headline, a side effect that did not
   land is `.failed` never a false Done; non-activating overlays with synchronous `orderOut`; the
   canonical gesture compass; reuse-don't-reinvent.

---

## 6. OpenSpec authoring rules (every new slice — same as blueprint §7)

- Mirror `openspec/changes/add-gesture-previews-and-bindings/` structure EXACTLY: `proposal.md`
  (Why / What Changes / Capabilities [New + Modified] / Impact), `design.md` (Context / Goals-NonGoals /
  numbered Decisions / per-component target-split + verification), `tasks.md` (numbered `## N.` with
  `- [ ]` + verification notes), `specs/<capability>/spec.md` deltas using
  `## ADDED/MODIFIED/REMOVED Requirements` → `### Requirement:` → `#### Scenario:` WHEN/THEN.
- Read the existing spec under `openspec/specs/<capability>/` first so your delta is a TRUE delta.
- Add `.openspec.yaml` (`schema: spec-driven`, `created: 2026-06-23`).
- **Do NOT write Swift / application code in the planning run — OpenSpec markdown artifacts only.**
- Each change MUST pass `openspec validate <change> --strict`.
