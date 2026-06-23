# AI Agent V2.5 — Roadmap Addendum (Compute Tiers · Media · Fleet · Full Potential)

**Status:** integration-welded onto the V2 nine-slice plan. Six new slice architects each authored an
OpenSpec change under `openspec/changes/ai-{compute-tiers,media-runtime,local-image-generation,
video-animation-generation,model-fleet,full-potential-toggle}/`; this document is the integration
architect's synthesis for the V2.5 wave — the index, the implementation order welded *after* the
existing nine waves, the cross-slice conflict pass (the six against each other AND against the nine),
and the readiness call.

This is the companion to **`docs/ai-agent-v2-roadmap.md`** (the nine-slice roadmap) and rides on the
binding contract sketches in **`docs/ai-agent-v2-addendum-compute-media-fleet.md`** (read that first;
it pins the new shared types §A1/§B1/§C1/§D1) and **`docs/ai-agent-v2-blueprint.md`** (the original
nine §3.x contracts). Do **not** edit the existing roadmap — this file is the V2.5 delta.

**All six new changes pass `openspec validate <change> --strict` (exit 0, re-run during this pass).**

---

## 1. The six new changes (index)

| # | Change | Capability | One-line role |
|---|---|---|---|
| 1 | [`ai-compute-tiers`](../openspec/changes/ai-compute-tiers/) | `on-device-ai-runtime` (delta) | The **second lane**: `ComputeLane{.gpu,.cpuTernary}` + the pure `LaneRouting` role→lane policy; a CPU ternary `LLMRuntime` conformer for short structured bursts; the additive lane-affinity hint so a parked subagent advances on CPU concurrently with the foreground GPU reply. Owns §A1. |
| 2 | [`ai-model-fleet`](../openspec/changes/ai-model-fleet/) | `on-device-ai-runtime` + `configuration-hub` (delta) | Evolves `ModelManager` from one-resident-runtime into a **registry with residency/eviction**: extends `ModelDescriptor` (`role`/`lane`/`provider`/`residencyBytes`/`maxContextTokens`), the `ModelRegistry` protocol, the pure 48 GB `ResidencyPlanner` (a video/FP16-image gen evicts chat), and the cloud members (Claude, GLM-5.2) that are never resident. Owns §C1. |
| 3 | [`ai-media-runtime`](../openspec/changes/ai-media-runtime/) | `ai-generative-media` (new) + `ai-command-tasks` (delta) | The **second runtime seam**: `MediaRuntime` parallel to `LLMRuntime` (a long async job → a file), the media value types (§B1), `generate_image`/`generate_video` as `ToolDescriptor`s, the `MediaGenSink` route-loop executor, the seed (img2img/img2video) path, and the dual output (Files-band gallery asset + canvas player). Owns the seam/tools/sink/output, not the backends. Owns §B1. |
| 4 | [`ai-local-image-generation`](../openspec/changes/ai-local-image-generation/) | `ai-generative-media` (delta) | A concrete **local image** `MediaRuntime` (mflux/FLUX-class MLX, in-process), the Q4 (~7 GB co-resident) / FP16 (~24 GB evicts-chat) descriptor variants, the pure `ImageResidencyClass` classifier, seed-driven img2img/inpaint, honest RAM/heat/latency disclosure. The honest *local* default (M5 diffusion is compute-bound). |
| 5 | [`ai-video-animation-generation`](../openspec/changes/ai-video-animation-generation/) | `ai-generative-media` (delta) | The **video** backend(s): cloud-escalation default (`CloudVideoRuntime`, `.dangerous` + rolling-24h budget cap + audit, the Claude-handoff template applied to video), the frontier local LTXV backend behind the master toggle (35 GB+, minutes/clip, evicts chat), img2video from the seed, one seam two interchangeable backends. |
| 6 | [`ai-full-potential-toggle`](../openspec/changes/ai-full-potential-toggle/) | `tunable-settings` + `configuration-hub` (delta) | The **master gate**: `fullPotentialEnabled` (default OFF) + five sub-flags, the pure `FullPotentialGate` (`master ∧ subFlag ∧ aiCommandsEnabled`), one Hub page with cost-in-the-same-breath disclosure, panic-off relock. Owns §D1. Each heavy slice consults the gate before activating. |

---

## 2. Implementation order (welded after the existing nine waves)

The nine-slice roadmap (`ai-agent-v2-roadmap.md` §4) sequences Waves 1–4 ending at
`ai-conversational-canvas`. The V2.5 wave assumes **the existing Wave 1–2 types are already on disk**
(`AgentMessage`/`AgentConversation`/`AgentSessionID` from `ai-conversation-runtime`; `LLMChatRequest`/
`chat()` and `BatchedLLMRuntime`/`ParkScheduler` from `ai-batched-runtime-and-context` /
`ai-parked-sessions`; `ToolDescriptor`/`ToolRegistry`/`WritePolicyTier`/route loop from
`ai-tool-routing`; `AuditLog`/`WritePolicyResolving` from `ai-background-autonomy`). Apply V2.5 as a
**fifth wave** (addendum §4), in this strict order:

> **Wave 5:** `ai-compute-tiers` → `ai-model-fleet` → `ai-media-runtime` →
> {`ai-local-image-generation`, `ai-video-animation-generation`} → `ai-full-potential-toggle`

1. **`ai-compute-tiers`** — first, because it **OWNS `ComputeLane`** (§A1), and every later V2.5 slice
   types against it: `ai-model-fleet`'s `ModelDescriptor.lane` *is* `ComputeLane?`; the image/video
   backends declare `lane: .gpu`; the toggle gates `cpuLaneEnabled`. It amends the single-GPU assumption
   on `on-device-ai-runtime` (MODIFIED "Targets capable hardware only" + ADDed two-lane requirements) and
   adds the additive lane-affinity hint consumed by the already-landed `ParkScheduler`/`BatchedLLMRuntime`
   shapes — it edits neither sibling's files.
2. **`ai-model-fleet`** — second, because it **needs the lane concept** (`ModelDescriptor.lane:
   ComputeLane?`) and supplies the **registry + residency planner** the media slices ask `ensureResident`
   on. It registers the ternary descriptor compute-tiers introduced (`role: .ternaryChat`,
   `lane: .cpuTernary`) and the image/video descriptors the backends supply, and the cloud members
   (Claude, GLM-5.2). Evolves `ModelManager` through the existing `ModelProvisioner` seam (no API change).
3. **`ai-media-runtime`** — third, because it **OWNS the `MediaRuntime` seam + the `generate_*` tools +
   `MediaGenSink` + the dual output** (§B1). It registers the media tools in the already-landed
   `ToolRegistry` (via `ToolContributor`, no route-loop change), maps output to the existing Files-band
   `.fileEntry`, and parks via the existing `ParkScheduler`. The two backends drop into this seam.
4. **`ai-local-image-generation` + `ai-video-animation-generation`** — fourth, **in parallel**: both are
   pure `MediaRuntime` conformers behind the seam (depend on it) plus their fleet descriptors (depend on
   the registry). They share no types with each other (image is `capabilities:[.image]`, video is
   `[.video]`; distinct descriptor variants, distinct provider keys), so order between them is free.
5. **`ai-full-potential-toggle`** — last, because it **gates everything new (and the existing heavy
   slices)**: `cpuLaneEnabled`/`batchedRuntimeEnabled`/`mediaGenEnabled`/`backgroundAutonomyEnabled`/
   `fleetCloudEscalationEnabled` under the `fullPotentialEnabled` master. The pure `FullPotentialGate`
   must exist for each heavy slice's check-site; landing it last lets every gated slice's flag and cost
   line already be on disk to wire into the one Hub page. (Architects planned it in parallel against the
   addendum's pinned §D1 keys, so the plan does not block — only the *apply* is last.)

**Rationale for the spine** (compute → fleet → media → backends → toggle): it is a topological walk of
the §4 weld DAG. Lane is the lowest primitive (a descriptor field); the fleet is the registry that
hosts every model *including* the lane-tagged ternary and the media backends; the media seam needs the
fleet to resolve which image/video runtime is resident; the backends need the seam; the toggle gates the
union. No back-edges: the toggle only *reads* flags the heavy slices consult, never the reverse.

---

## 3. Cross-slice conflict pass

Verified the new shared types match across the six AND against the nine, the V2.5 weld DAG is acyclic,
the gesture/error/overlay invariants are uniform, and every native-linked piece is `xcodebuild`
compile-verify-only. Findings below — all are **mechanical bind-time actions**, none re-plans a slice
(mirroring `ai-agent-v2-roadmap.md` §3 style).

### Verified consistent

- **`ComputeLane` (§A1)** — `ai-compute-tiers` writes it verbatim (`enum ComputeLane: String, Codable,
  Sendable { case gpu, cpuTernary }`); `ai-model-fleet` consumes it as `ModelDescriptor.lane:
  ComputeLane?`, the image/video backends declare `.gpu`, the toggle gates `cpuLaneEnabled`. Grep-confirmed
  no redefinition; `ai-model-fleet` independently states it imports `ComputeLane` "verbatim from §A1."
- **`AgentWorkRole` / `LaneRouting`** — owned by compute-tiers; the six-case role enum and the protocol are
  reproduced exactly. No consumer redefines them.
- **`MediaRuntime` + media value types (§B1)** — owned by `ai-media-runtime` verbatim
  (`MediaKind`/`MediaSize`/`MediaParameters`/`MediaRequest`/`MediaProgress`/`MediaAsset`/`MediaRuntime`).
  Both backend slices conform to the seam "as written," never redefine it: image declares
  `capabilities: [.image]`, video `[.video]`; both consume `MediaRequest.seed` as the first frame. The
  eight media requirement headers in `ai-media-runtime` and the backend-only requirement headers in the
  two backends are disjoint — no merge collision on `ai-generative-media`.
- **`ai-generative-media` is a NEW capability authored by `ai-media-runtime`; the two backends write
  `## ADDED Requirements` against it.** Because the base capability does not yet exist in
  `openspec/specs/`, `ADDED` is the correct OpenSpec op for the backends (net-new requirements layered on
  a capability a sibling introduces in the same wave). Validate is clean (exit 0) on all three.
- **`generate_image`/`generate_video` ride the EXISTING route loop** — they are `ToolDescriptor`s
  contributed via the existing `ToolContributor` seam; `MediaGenSink` is just another sink the
  route→execute→continue loop dispatches to. No new control flow. The `ai-command-tasks` delta is one
  `## ADDED Requirement` ("Media generation is a routed tool executed by a media sink, not a new control
  flow") — disjoint from `ai-tool-routing`'s six existing `ai-command-tasks` requirement headers, so the
  capability composes additively.
- **Write-policy + audit reuse** — image `.confirm`, cloud video `.dangerous` + budget cap; both reuse
  `WritePolicyTier`/`AuditLog`/`WritePolicyResolving` (owned by `ai-background-autonomy`, §3.7) and the
  `ai-claude-handoff` budget/rate-cap template (§3.8). No new gating mechanism; the video `VideoBudget` is
  the `HandoffBudget` pattern reused (`now:`-injected rolling-24h ledger).
- **Park + Files-band reuse** — media parks via the existing `ParkScheduler` (the notch glows on
  completion / `needsYou`); output lands as the existing Files-band `.fileEntry` (no new browser). Both
  are consumed shapes from `ai-parked-sessions` / `files-band`, unedited.
- **Gesture compass uniform** — the media canvas player resolves with the canonical two-finger compass
  (DOWN=extract only at canvas top → save/paste/set-as, RIGHT=discard, sub-threshold scroll = no-op),
  identical to the nine-slice canvas. No new gesture surface; no recognizer edit; interpretation at the
  `AppCoordinator` seam.
- **Error taxonomy** — exactly the two addendum-sanctioned new enums appear: `MediaError` (owned by
  `ai-media-runtime`, the backends map vendor errors into it at their boundary) and `FleetError` (owned by
  `ai-model-fleet`, only the cases `RuntimeError` cannot carry). `ai-compute-tiers` correctly prefers
  extending `RuntimeError` over a `ComputeError`. All route through the single `AIError.message(for:)`,
  surfaced bounded + non-blocking, never `NSAlert`, never raw error in a headline.
- **`configuration-hub` deltas compose** — `ai-model-fleet` (fleet roster + cloud badge),
  `ai-full-potential-toggle` (the Full Potential section), and the existing-wave `ai-background-autonomy`
  (whitelist + audit) each `## ADDED` disjoint requirement headers on the AI page. No collision.
- **Master gate keys (§D1) consumed, not redefined** — `ai-full-potential-toggle` OWNS the six keys;
  compute-tiers reads `cpuLaneEnabled`, media + backends read `mediaGenEnabled`, fleet reads
  `fleetCloudEscalationEnabled`. Each slice's proposal lists them as "consumed, not owned."
- **Native-linked split marked everywhere** — every concrete backend (`TernaryCPURuntime`,
  `MFluxImageRuntime`, `CloudVideoRuntime`/`LocalLTXVRuntime`), real residency/eviction with real weights,
  and the canvas media player overlay are `xcodebuild` compile-verify-only; the seams, value types,
  policy/residency MATH, and stubs (`StubTernaryRuntime`/`StubMediaRuntime`/stub video runtimes) are
  MLX-free Core `swift test`-verified. The `*.bundle` metallib copy must not regress.

### Conflicts found + resolutions

1. **`ModelDescriptor.maxContextTokens` is ADDed by TWO slices (cross-wave).** The existing-wave
   `ai-batched-runtime-and-context` ADDs `ModelDescriptor.maxContextTokens` (for the
   `agentContextTokens` budget); the new-wave `ai-model-fleet` *also* lists `maxContextTokens` among the
   fields it adds to `ModelDescriptor` (§C1 carries it on the descriptor). **Resolution:** the field has
   ONE definition. `ai-batched-runtime-and-context` (earlier wave) lands `maxContextTokens` first;
   `ai-model-fleet` adds `role`/`lane`/`provider`/`residencyBytes` **only**, and treats `maxContextTokens`
   as **already present** (it carries the field on the descriptor, it does not re-declare it). Fleet's own
   design already scopes this honestly ("this slice only *carries* `maxContextTokens` on the descriptor";
   context-tuning sliders stay batched's). At apply time, fleet's `ModelDescriptor` extension is a
   **superset patch** over batched's field — adding the four fleet fields next to the existing
   `maxContextTokens`, not a second declaration of it. Mechanical; no shape renegotiation.

2. **`ModelDescriptor.capabilities` type: `Set<Modality>` (live) vs `Set<String>` (§C1 sketch) vs the
   backends' string tags.** §C1 sketches `capabilities: Set<String>`; the live descriptor is
   `capabilities: Set<Modality>`; `ai-local-image-generation` writes `capabilities: ["image","img2img",
   "inpaint"]` (string tags). **Resolution:** keep the **live `Set<Modality>`** (fleet's design D explicitly
   honors §C1's *field shape* while keeping the existing `Set<Modality>` — §C1's `Set<String>` is the
   sketch stand-in for the real capability set, not a mandate to change the type). The backends' string
   tags (`"img2img"`/`"inpaint"`) bind to **`Modality` cases** (or are carried as a separate descriptor
   tag set the image runtime reads) — the image slice must populate `Modality` values, not raw strings,
   when it supplies its descriptors. Bind action: at `ai-local-image-generation` apply, map its
   `["image","img2img","inpaint"]` tags onto the descriptor's `Modality`-typed capability set (extend
   `Modality` with the img2img/inpaint cases if absent). Low risk; the data exists either way.

3. **`ModelDescriptor` `Codable`: §C1 sketches it `Codable`; the live descriptor is NOT.** §B1's
   `MediaAsset` IS `Codable` (it persists), but §C1's `ModelDescriptor` `Codable` is sketch-only — fleet's
   design keeps the descriptor non-`Codable` (it is constructed in code; only the selected model **id**
   persists via the existing `ModelSelector`). **Resolution:** no consumer may assume
   `ModelDescriptor: Codable`. The image/video backends persist their **selection key** (`imageModelID` /
   `videoProvider`), never the descriptor. Confirm at apply that no backend serializes a descriptor.
   Already honored in every proposal; just flag it so a later author doesn't add `Codable` to satisfy the
   §C1 sketch literally.

4. **`mediaVideoBudgetPerDay` is referenced by `ai-model-fleet` but OWNED by
   `ai-video-animation-generation`.** The fleet's Hub roster displays a cloud member's per-day-$ figure
   and design D6 references a `$ / per-day cap`, but the key `mediaVideoBudgetPerDay` is owned by the video
   slice (addendum §1). Fleet's "Consumes (verbatim)" line names `fleetCloudEscalationEnabled` /
   `fullPotentialEnabled` but **not** `mediaVideoBudgetPerDay`. **Resolution:** the key has one owner —
   `ai-video-animation-generation`. The fleet roster's cloud-cost display **reads** `mediaVideoBudgetPerDay`
   (consume, do not define). Since the video slice lands AFTER the fleet in Wave 5, the fleet's roster
   reads the key through a read-seam that is `nil`/"budget set by Video" until the video slice supplies it
   — exactly the same forward-reference pattern the nine-slice roadmap used for the
   `ContextBudgetProviding` injection. Tightening fleet's "Consumes" line to list `mediaVideoBudgetPerDay`
   would remove the ambiguity (markdown-only; non-blocking — flagged by the per-slice review).

5. **`imageModelID` / `videoProvider` selection keys cross fleet ↔ backend.** The fleet REGISTERS image
   and video descriptors but the **selection keys** are owned by the backends: `imageModelID`
   (`ai-local-image-generation`) selects the Q4-vs-FP16 image descriptor; `videoProvider`
   (`ai-video-animation-generation`) selects cloud-vs-localLTXV. **Resolution:** no conflict, but the
   binding direction must be explicit — the **fleet's registry is the source of descriptors; the backends'
   keys select among them.** At apply, the fleet's roster reads `imageModelID`/`videoProvider` as the
   selected-member pointers (consume), and the backends supply the descriptors the keys point at. Both
   land after the fleet, so the fleet roster tolerates an unset key (defaults to the Q4 image / cloud
   video) until the backend slice lands. Mechanical forward-reference, identical to conflict 4.

6. **Lane ordering against the existing `ParkScheduler`/`BatchedLLMRuntime` shapes.** `ai-compute-tiers`'s
   lane-affinity hint must attach to `ParkScheduler`'s runnable session and be read by the batched
   runtime — but both seams are owned by EARLIER (already-landed) slices and their signatures
   (`runnableSessions(now:maxSlots:)`, `batchStep(...)`) are pinned and unchanged. **Resolution:** the hint
   is **additive and carried beside** the pinned signatures (a `LaneAffinity` value the scheduler attaches
   to a `ParkedSession`/the dispatch, NOT a new parameter on the pinned methods). Compute-tiers amends this
   via MODIFIED/ADDed requirements on `on-device-ai-runtime` and does **not** edit the batched or parked
   slice files. Confirm at apply that the hint rides as an attached value, not a signature change — the
   compute-tiers spec already says exactly this.

7. **Three slices add `on-device-ai-runtime` deltas this wave; four total across both waves.** Existing
   wave: `ai-conversation-runtime` (MODIFIES "Swappable model runtime abstraction" + ADDs conversation
   reqs) and `ai-batched-runtime-and-context` (ADDs batched/context reqs). New wave: `ai-compute-tiers`
   (MODIFIES "Targets capable hardware only" + ADDs two-lane reqs) and `ai-model-fleet` (ADDs fleet/registry
   reqs). **Resolution:** all four compose because their requirement headers are **pairwise disjoint** (the
   one MODIFIED header each touches a *different* base requirement: conversation-runtime → "Swappable model
   runtime abstraction", compute-tiers → "Targets capable hardware only"; grep-confirmed only
   `ai-compute-tiers` modifies the hardware requirement in the active set). The synced capability spec
   composes cleanly. No collision.

### Against the existing nine — no regressions

- The two `LLMRuntime` consumers added this wave (the CPU ternary conformer, the media seam) honor the
  blueprint §0 reuse rule: the ternary model is **another `LLMRuntime` conformer** (not a new protocol);
  the media seam is a **parallel** `MediaRuntime`, explicitly NOT bolted onto `LLMRuntime`. Neither forks
  the model seam every nine-slice consumer depends on.
- `ai-model-fleet` evolves `ModelManager` through the **existing `ModelProvisioner`/`runtimeFactory`**
  (no API change), preserving the nine-slice assumption that the batched runtime plugs in behind the same
  seam. A **fleet-of-one stays byte-for-byte today's behavior** (and the nine-slice batched runtime's
  plug-in path).
- The master toggle's `batchedRuntimeEnabled` / `backgroundAutonomyEnabled` flags gate the EXISTING heavy
  slices. Per `ai-full-potential-toggle`'s design, those slices' check-site requirements are authored in
  **their own** files, not edited by the toggle slice — so the weld onto the nine is "each slice consults
  the gate," not a rewrite of the nine.

---

## 4. Open questions needing a human decision

Tuning values and small policy choices the architects flagged as not derivable on paper. None blocks
applying `ai-compute-tiers` (the first V2.5 slice). Resolve during run-verify on the user's stable-signed
build or at the relevant Wave-5 step.

- **Ternary model choice (compute-tiers):** which concrete small ternary/BitNet-class model the
  `TernaryCPURuntime` carries (the addendum pins "small ternary/BitNet-class," not a specific checkpoint).
  Needs a named model + its real `residencyBytes` (~0.5 GB target) and a measured CPU per-token rate to
  confirm the short-bursts-only constraint holds on M5.
- **Cloud video provider choice (video):** the addendum names "LTX Studio's hosted API / equivalent" —
  the specific hosted provider, its API shape (upload prompt + optional seed, poll progress, fetch file),
  and the per-clip $ order that calibrates `mediaVideoBudgetPerDay` are a human decision (real money +
  data off-device). The seam is built provider-agnostic; the choice is a config, not a re-plan.
- **`mediaVideoBudgetPerDay` default + the per-day-$ display value (video / fleet):** the actual default
  cap and the $-figure the fleet roster shows. Ground in the chosen provider's real per-clip price.
- **`imageModelID` default + quant policy (local-image):** Q4 (~7 GB, co-resident) is the documented
  default; confirm the FP16 (~24 GB, evicts-chat) opt-in is exposed and that the exact `residencyBytes`
  numbers match the chosen mflux/FLUX checkpoint at code time.
- **Image/video tuning (local-image / video):** default diffusion `steps`, `guidance`, `MediaSize`
  presets, and the per-clip `durationMs` ceiling — feel-only, calibrated on the signed build against real
  latency/heat.
- **The eviction "FP16 threshold" wording (fleet):** fleet design D3 describes a qualitative "FP16
  threshold" for evict-chat. It is arguably **emergent** (the target simply doesn't fit the 48 GB budget
  given the resident set + KV) rather than a named constant — confirm the planner stays pure
  `residencyBytes`-vs-`budgetBytes` math with no hard-coded threshold (cosmetic; scenarios are correct
  either way).
- **`Modality` extension for img2img/inpaint tags (conflict 2):** confirm `Modality` gains
  `.img2img`/`.inpaint` cases (vs carrying those as a separate descriptor tag set) — a small type decision
  at the `ai-local-image-generation` apply step.
- **Cost-disclosure copy (full-potential):** the exact RAM/heat/latency/$ strings on each sub-toggle row
  are make-or-break for the honest-surface ethos and are feel/wording — finalize on the real Hub page in
  the signed build.

---

## 5. Readiness

**Ready for implementation, after the existing nine.** All six V2.5 changes validate `--strict` (exit 0,
re-run this pass), the new shared types (`ComputeLane` §A1, `MediaRuntime`+value types §B1,
`ModelRegistry`/extended `ModelDescriptor` §C1, the master gate §D1) match across the six AND fold onto
the nine without redefining a nine-slice type or forking the `LLMRuntime`/`ModelProvisioner` seams, the
Wave-5 weld DAG is acyclic, and every native-linked backend + overlay is marked `xcodebuild`
compile-verify-only with the real correctness deferred to the user's stable-signed build.

The seven conflicts in §3 are all **mechanical bind-time actions** folded into the Wave-5 apply order:
treat `maxContextTokens` as already-present when fleet extends the descriptor (1); map the image backend's
string tags onto `Modality` (2); never assume `ModelDescriptor: Codable` (3); read `mediaVideoBudgetPerDay`
through a forward-reference seam owned by the video slice (4); let the fleet roster tolerate unset
`imageModelID`/`videoProvider` until the backends land (5); carry the lane-affinity hint as an attached
value beside the pinned scheduler/batch signatures (6); and rely on the disjoint requirement headers so the
four `on-device-ai-runtime` deltas compose (7). None re-plans a slice. `/opsx:apply` can start on
`ai-compute-tiers` (Wave 5, first) once the existing nine have landed.
