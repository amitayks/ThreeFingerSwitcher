> Decomposed for a workflow fan-out: §1 is the pure gate substrate (do first), §2 is persistence, §3 the settings→gate adapter, §4 the Hub disclosure UX (App target — compile-verify + user run-verify), §5 the cross-slice weld contract (specified, not edited into siblings), §6 verifies. Every item is MLX-free Core verified by `swift test` unless noted; this slice OWNS no UI gesture and **never builds/signs the `.app`**. The key names `fullPotentialEnabled` / `cpuLaneEnabled` / `batchedRuntimeEnabled` / `mediaGenEnabled` / `backgroundAutonomyEnabled` / `fleetCloudEscalationEnabled` are pinned by addendum §D1 and used verbatim; `enableAICommands` is CONSUMED from `tunable-settings`.

## 1. The pure gate (Core type substrate — do first)

- [ ] 1.1 Add `AI/FullPotential/FullPotentialGate.swift`: `FullPotentialCapability` enum (`cpuLane`/`batchedRuntime`/`mediaGen`/`backgroundAutonomy`/`fleetCloud`, `String`/`CaseIterable`/`Codable`/`Sendable`) mapped 1:1 to the five sub-flags. DO NOT redefine `ComputeLane`/`MediaRuntime`/`ModelRegistry`/`WritePolicyTier` (those are sibling-owned; this enum only NAMES the capabilities the flags gate). *Verify: `swift test` — `allCases.count == 5`; each case's `rawValue` is stable.*
- [ ] 1.2 Add `FullPotentialFlags` (the gate's pure input: `aiCommandsEnabled` + `fullPotentialEnabled` + the five sub-flags, `Equatable`/`Sendable`). *Verify: `swift test` — value-type equality.*
- [ ] 1.3 Add `FullPotentialGate.isUnlocked(_:) -> Bool`: `master ∧ subFlag ∧ aiCommandsEnabled`; master OFF ⇒ every capability locked; `ai-commands` OFF ⇒ every capability locked; each sub-flag gates ONLY its own capability. Total, pure, no throw/async/IO. *Verify: `swift test` — full truth table: (a) `aiCommandsEnabled=false` ⇒ all five locked regardless; (b) `fullPotentialEnabled=false` ⇒ all five locked; (c) with both masters on, flipping one sub-flag unlocks exactly one capability and no other; (d) iterate `allCases` to assert exhaustive gating.*

## 2. Persistence (Core — default OFF, legacy-load, reset preserve-set)

- [ ] 2.1 Add the six persisted `Bool` keys to `App/AppSettings.swift`: `fullPotentialEnabled` + `cpuLaneEnabled` + `batchedRuntimeEnabled` + `mediaGenEnabled` + `backgroundAutonomyEnabled` + `fleetCloudEscalationEnabled`, each **default false**. *Verify: `swift test` — fresh store reads all six false.*
- [ ] 2.2 Ensure legacy-load: settings written before this wave decode with all six absent ⇒ false (mirroring `enableDeviceLink`/`enableAICommands` legacy behavior; no existing settings reset). *Verify: `swift test` — decode a fixture lacking the keys ⇒ all six false; pre-existing keys unchanged.*
- [ ] 2.3 Add the six keys to the AI-opt-in **reset preserve-set** (reset-to-defaults retains them, like `enableAICommands`/`keepClipboardHistory`/selected model). *Verify: `swift test` — set the six true, reset-to-defaults, read back true (NOT zeroed); a normal tunable still resets.*

## 3. Settings → gate adapter (Core)

- [ ] 3.1 Add a pure mapping from `AppSettings` (the six keys + the existing `enableAICommands`) to `FullPotentialFlags`, and a convenience `AppSettings.fullPotentialGate -> FullPotentialGate`. CONSUME `enableAICommands` verbatim; do not redefine the AI-commands opt-in. *Verify: `swift test` — a known settings fixture maps to the expected `FullPotentialFlags`; `enableAICommands` flows into `aiCommandsEnabled`; `gate.isUnlocked(.mediaGen)` matches the fixture.*

## 4. The Hub Full Potential section (App target — compile-verify + user run-verify)

- [ ] 4.1 Add a **Full Potential** section to the Hub **AI** feature page (`Hub/`): the master toggle (`fullPotentialEnabled`) rendered FIRST, then the five sub-toggle rows (iterate `FullPotentialCapability.allCases`), shared Liquid Glass presentation. *Verify: `xcodebuild` compile; **user run-verifies** the section appears on the AI page in a stable-signed build.*
- [ ] 4.2 Render each sub-toggle row's **persistent cost line** inline as its caption (RAM / heat / latency / $ per design Decision 1's table) — NOT a tooltip/disclosure. The `mediaGen` row states "the assistant goes quiet while it paints" (chat eviction); the `fleetCloud` row states "spends real money + sends data off-device; budget-capped + audited". *Verify: `xcodebuild` compile; **user run-verifies** every row shows its cost line inline, always visible.*
- [ ] 4.3 Progressive enablement: the five sub-toggles render **disabled (visibly relocked)** while the master is off; flipping the master OFF relocks all five in the UI while RETAINING their persisted values (no zeroing). *Verify: `xcodebuild` compile; **user run-verifies** sub-toggles disabled until master on; panic-off relocks while a sub-flag's prior value survives a re-arm.*
- [ ] 4.4 Any settings-store persist/load failure surfaces bounded + non-blocking (the existing AppSettings error path; clean headline, opt-in details) — **never** `NSAlert.runModal`, never raw error text in a headline. (The gate itself is total and surfaces no error.) *Verify: `xcodebuild` compile; review — no app-modal alert, no raw error interpolation.*

## 5. The cross-slice weld contract (specified here; consumed by siblings — NOT edited into their files)

- [ ] 5.1 In this change's spec deltas, state the shared contract: each heavy slice (`ai-compute-tiers`, `ai-batched-runtime-and-context`, `ai-media-runtime` + backends, `ai-background-autonomy`, `ai-model-fleet` cloud members) consults `FullPotentialGate.isUnlocked(capability)` before activating, and behaves as feature-off when locked. DO NOT edit any sibling slice's source or spec files. *Verify: review — the deltas are **ADDED** requirements on `tunable-settings`/`configuration-hub` only (genuinely new, not rewrites of existing requirements); `git status` shows no sibling change-dir edits.*
- [ ] 5.2 Confirm the consumed names match the addendum §D1 pins exactly (`fullPotentialEnabled` + the five sub-flags) and `enableAICommands` matches `tunable-settings`. *Verify: review — verbatim key names; no conflicting redefinition of a sibling-owned type.*

## 6. Spec sync + validation

- [ ] 6.1 Write the `tunable-settings` delta (ADDED: the Full Potential keys, gate rule, default-OFF/persistence/legacy/reset, the heavy-slice-consults-the-gate contract). *Verify: `openspec validate ai-full-potential-toggle --strict`.*
- [ ] 6.2 Write the `configuration-hub` delta (ADDED: the Hub AI-page Full Potential section — master + five cost-disclosing sub-toggles, disabled-until-master, panic-off relock, Liquid Glass). *Verify: `openspec validate ai-full-potential-toggle --strict`; review the deltas are true ADDED requirements (not rewrites of existing AI-page requirements).*
