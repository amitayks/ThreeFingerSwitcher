## Context

This is the **last** slice of the V2.5 compute/media/fleet wave (addendum §4 implementation order: it gates everything new + the two existing heavy slices). It OWNS the **master gate** (`fullPotentialEnabled`) + the five per-capability sub-flags (addendum §D1), the **pure gating logic** every heavy slice checks before activating, and the **disclosure UX** — one Hub page where each sub-toggle states its RAM / heat / latency / $-cost in the same breath it offers the capability.

Read these before the design — the ground truth this slice plugs into, not forks:

- **`docs/ai-agent-v2-addendum-compute-media-fleet.md` §D1** — pins the gate's exact key set: the master `fullPotentialEnabled` (default false) and the five sub-flags `cpuLaneEnabled` / `batchedRuntimeEnabled` / `mediaGenEnabled` / `backgroundAutonomyEnabled` / `fleetCloudEscalationEnabled`. "Each heavy slice CHECKS its flag before activating." This slice writes the real types behind those names. §5.6 (Default OFF) and §5.5 (a heavy gen evicts chat) are the honesty mandates this disclosure UX implements.
- **`docs/ai-agent-v2-blueprint.md`** — base conventions: one error taxonomy + one `AIError.message(for:)` translator, bounded + non-blocking surfacing, never `NSAlert.runModal`/raw-error-in-headline, reuse-don't-reinvent (`AppSettings`, the Hub page pattern), no degraded/low-end paths (M5/M4 only).
- **`openspec/specs/tunable-settings/spec.md`** — the existing opt-in pattern this gate mirrors: the **AI commands opt-in** (`enableAICommands`, default OFF, gates the band + model), the **clipboard/device-link** opt-ins (immediate, no relocation/permission/re-login), and the **reset-to-defaults** preserve-set (gesture relocations, clipboard/AI opt-ins, excluded apps, selected model are preserved, not zeroed). The Full Potential flags join that preserve-set.
- **`openspec/specs/configuration-hub/spec.md`** — the AI feature page already exists (the model-management section). This slice adds a **Full Potential** section to it, in the shared Liquid Glass language, mirroring how the launcher/Space-row opt-ins disable their dependent tunables.
- **Sibling slices (authored concurrently)** — `ai-compute-tiers` (`ComputeLane`/`LaneRouting`, §A1), `ai-media-runtime` (`MediaRuntime`, §B1) + `ai-local-image-generation`/`ai-video-animation-generation`, `ai-model-fleet` (`ModelRegistry`/`ModelDescriptor`, §C1), and the existing heavy `ai-batched-runtime-and-context` + `ai-background-autonomy`. This slice **references** their types as the things the sub-flags gate; it depends on the addendum's pinned `fullPotentialEnabled` (§D1), NOT on sibling change files existing yet.

This slice owns no UI gesture and no recognizer state. It is a pure Core flag + gate that the heavy slices read and one Hub page renders.

## Goals / Non-Goals

**Goals:**
- One **master gate** `fullPotentialEnabled` (default OFF → V2.5 ships calm) + five per-capability sub-flags, each persisted, default OFF, preserved by reset like the other AI opt-ins.
- A pure, total **`FullPotentialGate`** (`swift test`-verified) that answers "is capability X unlocked": `master ∧ subFlag ∧ aiCommandsEnabled`. Turning the master OFF closes every gate at once (the calm panic-off). Never builds/signs/touches MLX.
- A **disclosure UX**: each sub-toggle states its RAM / heat / latency / $-cost inline, persistently (not behind a tooltip). The media + cloud rows state the hard truths plainly (chat eviction; real $ + data off-device, budget-capped).
- **Progressive enablement** on one Hub page: master first, then five sub-toggles disabled-and-visibly-relocked until the master is on; flipping the master OFF relocks all five while RETAINING their values.
- The **weld** specified as **ADDED** shared-contract requirements on `tunable-settings`/`configuration-hub` (the capabilities this slice owns) — **without editing the heavy slices' files**; each owning slice authors its own check-site requirement.

**Non-Goals:**
- The sub-capabilities' behavior, runtimes, residency math, costs-as-incurred, or any UI beyond the gate + its disclosure (each owned by its slice). This slice *discloses* costs; the owning slices *incur* them.
- The AI-commands master opt-in + model download + Calendar prompt (already `tunable-settings`; the gate consumes `enableAICommands`, it does not redefine it).
- Defining `ComputeLane`/`MediaRuntime`/`ModelRegistry`/`ModelDescriptor`/`WritePolicyTier`/`BatchedLLMRuntime` (owned by siblings) — referenced verbatim, never redefined.
- Changing the reset-to-defaults *mechanism* — the new keys join the existing AI opt-in preserve-set; reset's behavior is unchanged.
- Any Intel/low-end fallback, degraded path, new permission, gesture relocation, or re-login. Apple-Silicon M5 (M4 min) only.

## Decisions

### 1. The flag set — one master, five sub-flags, exactly the §D1 names

The persisted shape (in `AppSettings`), each a `Bool` default `false`:

| Key | Gates | Owning slice | Honest cost the row discloses |
|---|---|---|---|
| `fullPotentialEnabled` | **the master** | this slice | "Lights up the agent fleet. Each capability below states its own cost." |
| `cpuLaneEnabled` | the CPU ternary lane | `ai-compute-tiers` | **Heat / battery** — a second (CPU) lane runs concurrently; short structured bursts only, CPU per-token is slower. |
| `batchedRuntimeEnabled` | K-stream GPU batched runtime + growable context | `ai-batched-runtime-and-context` | **RAM + latency** — multiplexes K sessions over one weight read; larger context = more resident KV; latency rises under load. |
| `mediaGenEnabled` | image/video generation tools | `ai-media-runtime` + backends | **RAM (eviction) + latency + disk** — a heavy gen **evicts chat** ("the assistant goes quiet while it paints"); minutes per clip; tens of GB of weights. |
| `backgroundAutonomyEnabled` | parked auto-vs-escalate + whitelist + audit | `ai-background-autonomy` | **Unattended action** — the agent may act while you are away (whitelisted/contained writes only; dangerous ones still escalate; all audited). |
| `fleetCloudEscalationEnabled` | cloud members (Claude / GLM-5.2) | `ai-model-fleet` | **\$ + network + data off-device** — sends prompts to a paid cloud model; **budget-capped + audited**; off until armed. |

**Rationale:** the addendum (§D1, §1 persisted keys) pins these exact names; using them verbatim lets each sibling reference `settings.cpuLaneEnabled` etc. without negotiation. Five flags (not one per micro-feature) match the five heavy capabilities; the two image/video backends ride the single `mediaGenEnabled` because they share the `MediaRuntime` seam and the media-gen Hub experience is one concept to the user.

**Alternatives rejected:** (a) One flat list of independent opt-ins with no master — rejected: loses the single deliberate "release full potential" act and the one-switch panic-off; the calm default would be six separate "off"s the user must individually trust. (b) A single master with no sub-flags — rejected: the user cannot, say, allow the CPU lane (cheap) while keeping cloud spend (expensive) off; progressive, cost-aware enablement needs per-capability granularity. (c) Sub-flags persisted under a nested dictionary — rejected: flat camelCase `Bool`s match every existing `AppSettings` opt-in and the addendum's pinned key names.

### 2. The gating rule — `master ∧ subFlag ∧ aiCommandsEnabled`, total and pure

```swift
// Core, MLX-free. The single source of truth for "is capability X actually unlocked."
public enum FullPotentialCapability: String, CaseIterable, Codable, Sendable {
    case cpuLane            // ai-compute-tiers           → cpuLaneEnabled
    case batchedRuntime     // ai-batched-runtime-and-context → batchedRuntimeEnabled
    case mediaGen           // ai-media-runtime + backends → mediaGenEnabled
    case backgroundAutonomy // ai-background-autonomy      → backgroundAutonomyEnabled
    case fleetCloud         // ai-model-fleet cloud members → fleetCloudEscalationEnabled
}

public struct FullPotentialFlags: Equatable, Sendable {
    public var aiCommandsEnabled: Bool      // the existing AI feature opt-in (enableAICommands)
    public var fullPotentialEnabled: Bool   // the master
    public var cpuLane: Bool
    public var batchedRuntime: Bool
    public var mediaGen: Bool
    public var backgroundAutonomy: Bool
    public var fleetCloud: Bool
}

public struct FullPotentialGate: Sendable {
    public let flags: FullPotentialFlags
    public func isUnlocked(_ capability: FullPotentialCapability) -> Bool {
        // master closed → every capability closed (the calm panic-off)
        guard flags.aiCommandsEnabled, flags.fullPotentialEnabled else { return false }
        switch capability {
        case .cpuLane:            return flags.cpuLane
        case .batchedRuntime:     return flags.batchedRuntime
        case .mediaGen:           return flags.mediaGen
        case .backgroundAutonomy: return flags.backgroundAutonomy
        case .fleetCloud:         return flags.fleetCloud
        }
    }
}
```

**Rationale:** the fleet is a strict **subset** of the AI feature — if the AI-commands opt-in is off there is no model resident at all, so every fleet capability is meaningless; folding `aiCommandsEnabled` into the gate means a heavy slice does ONE check (`gate.isUnlocked(.mediaGen)`) instead of three scattered guards, and the master closing closes everything in one place. The gate is **total** (no throw, no async, no IO) so it is trivially `swift test`-able and can be called on any thread, in any sink, before activating. `FullPotentialCapability` is `CaseIterable` so the Hub can render the five rows by iterating, and a test can assert every case is gated.

**Alternatives rejected:** (a) Five free functions instead of an enum+gate — rejected: an enum gives the Hub one render loop and the tests one exhaustiveness check; a stringly-typed flag name invites typos. (b) Resolving the gate inside each sub-flag's setter (so `cpuLaneEnabled` auto-falses when the master is off) — rejected: that *destroys* the user's sub-flag choices on panic-off; the spec requires values be **retained** (inert) so re-arming the master restores the prior selection (mirrors the launcher tunables going inert, not zeroed). The gate computes unlock at read time; it never mutates the stored flags. (c) Omitting `aiCommandsEnabled` and trusting callers to also check it — rejected: scatters the invariant and risks a fleet capability activating with no model.

### 3. Default OFF, persistence, and reset — join the AI opt-in preserve-set

All six keys default **false**. They persist in `AppSettings` exactly like `enableAICommands` / `keepClipboardHistory` / `enableDeviceLink`. Settings written before this wave load with all six OFF (no key present → false), like every prior opt-in's legacy-load.

On **reset-to-defaults**, the six keys are **preserved** (not reset to off), joining the existing preserve-set (gesture relocations, clipboard/AI opt-ins, excluded apps, selected model) — for the same reason: re-acquiring full potential is a deliberate, possibly costly act (a media download, a cloud-budget decision), and a reset should not silently re-arm or silently disarm a fleet the user deliberately configured. **Rationale:** consistency with the documented reset semantics (`tunable-settings` Requirement "Feature pages preserve all tunables and persistence" / the configuration-hub Danger-zone reset). **Alternative rejected:** resetting the flags to off on reset-to-defaults — rejected: a reset is a *tunable* reset, and these are opt-ins (the spec already excludes opt-ins from reset); zeroing them would diverge from the AI-commands opt-in's own preserved behavior.

### 4. Disclosure UX — cost in the same breath, never behind a tooltip

Each sub-toggle row carries a **persistent, always-visible cost line** (RAM / heat / latency / $, per Decision 1's table), rendered as the row's caption beneath its title — not a hover tooltip, not a disclosure the user might never open. The two highest-cost rows state the hard truths in plain words: **mediaGen** — "the assistant goes quiet while it paints" (a heavy gen evicts chat, addendum §5.5); **fleetCloud** — "spends real money and sends data off-device; budget-capped + audited" (addendum §5.6, the Claude-handoff honesty pattern).

**Rationale:** the project's honest-surface ethos (CLAUDE.md: never let a fan scream / a bill arrive / the assistant fall silent as a surprise) applied to *capability cost*. A cost the user must hunt for is a hidden cost. **Alternatives rejected:** (a) Cost behind an info "i" popover — rejected: a popover is opt-in attention; the mandate is "in the same breath." (b) A single shared disclaimer for the whole section — rejected: each capability's cost differs in kind (heat vs RAM vs $); a per-row line is the truthful granularity. (c) Showing live RAM/heat telemetry — rejected: out of scope (no measurement subsystem here) and the disclosure is about *what the capability costs in principle*, which is stable copy, not a live gauge.

### 5. Progressive enablement + panic-off — master gates the rows visually; values retained

On the Hub Full Potential section: the **master toggle renders first**; the five sub-toggles render **disabled (visibly relocked)** whenever the master is off. Flipping the master OFF relocks all five **in the UI** while **retaining** their persisted values (so re-arming the master restores the prior selection). This mirrors the existing pattern where launcher/Space-row tunables are inert (no behavioral effect) while their opt-in is off, but their stored values survive.

**Rationale:** matches both the gate logic (Decision 2 reads, never mutates) and the established Hub idiom (disabled-but-reachable controls, `configuration-hub` "Disabled feature page still reachable"). **Alternative rejected:** hiding the sub-rows entirely while the master is off — rejected: the user can't preview what releasing full potential would offer, and the configuration-hub spec prefers *disabled-and-shown* over *hidden* for gated controls.

### 6. The weld — one boolean consult per heavy slice, specified not edited

Each heavy slice adds exactly **one** `gate.isUnlocked(capability)` consult before activating its runtime/lane/sink/cloud member; when the gate is closed the slice behaves as it does today with its feature off (no lane, no batched runtime, no media tool registered, no background auto-run, no cloud member resident/dispatchable). This change specifies the welds as:
- **ADDED** requirements on `tunable-settings` (the new Full Potential keys, the gate rule, and the shared "each heavy capability consults the gate" contract + per-flag persistence/default/reset) — these are genuinely new (no existing `tunable-settings` requirement names Full Potential or the gate, so this is a TRUE delta, not a rewrite),
- **ADDED** requirement on `configuration-hub` (the new Hub Full Potential section — also genuinely new; it neither renames nor rewrites the existing AI-page model-management requirements),
- and it does **NOT** edit `ai-compute-tiers` / `ai-batched-runtime-and-context` / `ai-media-runtime` / `ai-background-autonomy` / `ai-model-fleet` source or spec files. Those slices consume `FullPotentialGate` (a Core type), check it, and author the per-slice check-site requirement in their OWN deltas; the shared gate type + cross-slice contract live here.

**Rationale:** the addendum (§D1) says each heavy slice CHECKS its flag; centralizing the *gate type* + the *contract* here, while leaving the *check site* to each slice, keeps this slice from reaching into sibling files (which would conflict with concurrent authorship). **Alternative rejected:** this slice editing each heavy slice to insert the check — rejected: violates concurrent-authorship isolation and the binding rule ("without editing those slices' files").

### 7. No new error type — the gate is total

The gate does not throw; it returns a `Bool`. A capability being locked is **not** an error — it is the calm default. So no `<Slice>Error` is born here. The only failure surface is a persistence read/write of `AppSettings`, which is already the existing settings store's concern and already routes through the app's settled error path; this slice adds no new boundary. **Rationale:** the blueprint allows a new error enum *only if* `RuntimeError`/`TaskError` cannot carry it — here there is no failure to carry. **Alternative rejected:** a `FullPotentialError.locked` — rejected: locked is expected steady state, not an error; surfacing it as one would violate "a failure is observable `.failed`, never a false anything" by inventing a false failure.

## Target-split & verification

| Component | Target | Verified by |
|---|---|---|
| `AI/FullPotential/FullPotentialGate.swift` — `FullPotentialCapability`, `FullPotentialFlags`, `FullPotentialGate.isUnlocked(_:)` (pure resolver) | **MLX-free Core** | `swift build` + `swift test` — exhaustive truth table per capability (master off ⇒ all locked; ai-commands off ⇒ all locked; each sub-flag gates only its capability; `CaseIterable` exhaustiveness). |
| `AppSettings` persisted keys — `fullPotentialEnabled` + the five sub-flags (default false; legacy-load false; reset preserve-set) | **MLX-free Core** | `swift build` + `swift test` — defaults false; persist round-trip; legacy decode with keys absent ⇒ false; reset-to-defaults preserves all six (no new default leak). |
| `FullPotentialFlags`-from-`AppSettings` adapter (maps the stored keys + `enableAICommands` into the gate's input) | **MLX-free Core** | `swift test` — a known settings fixture maps to the expected `FullPotentialFlags`; `enableAICommands` flows into `aiCommandsEnabled`. |
| Hub **Full Potential** section (`Hub/` view code) — master toggle, five cost-disclosing sub-toggle rows, disabled-until-master, panic-off relock, Liquid Glass | **App target (native-linked)** | `xcodebuild` **compile-verify only** for the agent; **the user run-verifies** on a stable-signed build: rows disabled until master on, panic-off relocks while retaining values, cost lines visible inline. (An agent never builds/signs the `.app` — ad-hoc signing breaks TCC.) |
| The weld (each heavy slice's one `gate.isUnlocked` consult) | **the OWNING heavy slice's target** (Core or native, per slice) | The shared contract is specified here as an **ADDED** `tunable-settings` requirement; the per-slice **check site** is **implemented + verified in each owning slice**, not in this change's files. |

No component of this slice links MLX, downloads weights, spawns a process, or touches the build/sign path. The gate, the flags, and the adapter are pure Core (the majority of the slice). Only the Hub section needs the real app, and only for visual/interaction run-verification by the user.
