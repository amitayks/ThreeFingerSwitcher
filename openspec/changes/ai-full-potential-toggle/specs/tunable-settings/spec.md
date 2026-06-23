## ADDED Requirements

### Requirement: Release Full Potential master gate and sub-capability flags

The settings SHALL expose a **Release Full Potential** master opt-in, `fullPotentialEnabled`, that defaults to **OFF**, and five per-capability sub-flags it unlocks — `cpuLaneEnabled` (the CPU ternary lane), `batchedRuntimeEnabled` (the K-stream batched GPU runtime + growable context), `mediaGenEnabled` (image/video generation), `backgroundAutonomyEnabled` (parked auto-vs-escalate, whitelist, audit), and `fleetCloudEscalationEnabled` (cloud fleet members such as Claude / GLM-5.2) — each also defaulting to **OFF**. Like the clipboard-history and device-link opt-ins, none of these flags SHALL relocate any native gesture, require a re-login, or request a new permission; each SHALL take effect immediately when toggled. They SHALL persist across launches, and settings written before this feature SHALL load with all six OFF (no key present reads as false), leaving existing settings unchanged.

The flags SHALL be **preserved by reset-to-defaults** exactly like the other AI opt-ins (the AI-commands opt-in, the selected model): a reset SHALL NOT turn them on, nor turn them off — re-acquiring full potential is a deliberate, possibly costly act and a tunable reset SHALL NOT silently re-arm or disarm a configured fleet.

#### Scenario: Master and sub-flags default off

- **WHEN** the app loads with no prior Full Potential settings
- **THEN** `fullPotentialEnabled` and all five sub-flags (`cpuLaneEnabled`, `batchedRuntimeEnabled`, `mediaGenEnabled`, `backgroundAutonomyEnabled`, `fleetCloudEscalationEnabled`) are OFF

#### Scenario: Toggling needs no re-login, permission, or gesture change

- **WHEN** the user turns the master or any sub-flag on
- **THEN** it takes effect immediately, with no re-login, no native-gesture relocation, and no new permission prompt

#### Scenario: Flags persist across launches

- **WHEN** the user enables the master and a sub-flag and relaunches
- **THEN** both remain enabled and are reapplied

#### Scenario: Legacy settings load with the flags off

- **WHEN** settings written before this feature are loaded
- **THEN** all six keys read as false (no key present) and the existing settings are not reset

#### Scenario: Reset to defaults preserves the flags

- **WHEN** the user has enabled the master and some sub-flags and then resets to defaults
- **THEN** the six Full Potential flags retain their values (like the other AI opt-ins), while ordinary tunables return to their defaults

### Requirement: Full Potential gating rule resolves capability unlock

The system SHALL provide a pure, total gating rule that resolves whether a given Full Potential capability is **unlocked**: a capability SHALL be unlocked **only when** the AI-commands opt-in is on **AND** the master `fullPotentialEnabled` is on **AND** that capability's own sub-flag is on. When the master is OFF, **every** capability SHALL be locked at once (a single panic-off), and when the AI-commands opt-in is OFF every capability SHALL be locked (the fleet is a strict subset of the AI feature, which owns the resident model). The rule SHALL be pure (no side effects, no IO, no model linkage): it SHALL NOT mutate the stored flags — turning the master off SHALL relock the capabilities by computation while **retaining** each sub-flag's stored value, so re-arming the master restores the prior selection.

#### Scenario: Master off locks everything

- **WHEN** the AI-commands opt-in is on, every sub-flag is on, but `fullPotentialEnabled` is OFF
- **THEN** every Full Potential capability resolves as locked

#### Scenario: AI-commands off locks everything

- **WHEN** the AI-commands opt-in is OFF
- **THEN** every Full Potential capability resolves as locked regardless of the master or sub-flags

#### Scenario: A sub-flag gates exactly its own capability

- **WHEN** the AI-commands opt-in and the master are both on and only `mediaGenEnabled` is on among the sub-flags
- **THEN** the media-generation capability resolves as unlocked and no other capability does

#### Scenario: Panic-off retains sub-flag values

- **WHEN** the user has several sub-flags on, turns the master OFF, then turns the master back ON
- **THEN** the previously-on sub-flags are still on (their stored values were retained, not zeroed) and their capabilities resolve as unlocked again

### Requirement: Each heavy capability consults the gate before activating

Every gated heavy capability SHALL consult the Full Potential gating rule for its own capability and SHALL activate **only** when that capability resolves as unlocked; when it resolves as locked the capability SHALL behave exactly as it does with its feature off (no activation, no resident weights for it, no registered tool, no background action, no cloud member dispatched). Specifically: the CPU ternary lane SHALL NOT run unless `cpuLane` is unlocked; the batched runtime + growable context SHALL NOT activate unless `batchedRuntime` is unlocked; the image/video generation tools SHALL NOT be available unless `mediaGen` is unlocked; parked background auto-execution SHALL NOT run unless `backgroundAutonomy` is unlocked; and a cloud fleet member SHALL NOT be dispatchable unless `fleetCloud` is unlocked. This consult SHALL be the single gate each heavy slice checks; it SHALL NOT require any heavy slice to re-implement the master/AI-commands conjunction.

#### Scenario: A locked capability does not activate

- **WHEN** the master is off (so a capability is locked) and the agent would otherwise use that capability
- **THEN** the capability does not activate and the agent behaves as if that capability's feature were off

#### Scenario: Cloud escalation stays off until armed

- **WHEN** `fleetCloudEscalationEnabled` is off (or the master is off)
- **THEN** no cloud fleet member is dispatchable, no cloud spend can occur, and no data leaves the device for a fleet capability

#### Scenario: Unlocking one capability does not unlock the others

- **WHEN** the user unlocks only the CPU lane (`cpuLaneEnabled` on, master + AI-commands on, other sub-flags off)
- **THEN** the CPU ternary lane may run while the batched runtime, media generation, background autonomy, and cloud escalation all remain locked and inactive
