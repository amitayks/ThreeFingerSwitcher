## ADDED Requirements

### Requirement: The AI page hosts the Full Potential gate with cost disclosure

The Hub's **AI** feature page SHALL provide a **Full Potential** section that is the single surface for releasing and configuring the heavy AI capabilities. The section SHALL present, first, the **Release Full Potential** master toggle (`fullPotentialEnabled`), and beneath it the five per-capability sub-toggles — the **CPU lane** (`cpuLaneEnabled`), the **batched runtime** (`batchedRuntimeEnabled`), **media generation** (`mediaGenEnabled`), **background autonomy** (`backgroundAutonomyEnabled`), and **cloud escalation** (`fleetCloudEscalationEnabled`). All toggles SHALL persist their values with the same defaults (all OFF) and the same reset-to-defaults preservation as the other AI opt-ins, and SHALL use the shared **Liquid Glass** presentation consistent with the rest of the Hub.

Each sub-toggle SHALL state its **cost** — RAM, heat/battery, latency, and dollar cost as applicable — **inline and always visible** (as the row's caption, not behind a tooltip or a disclosure the user might never open), in the same breath it offers the capability. In particular the **media generation** row SHALL state plainly that a heavy generation makes the assistant go quiet while it paints (it evicts chat under the memory budget), and the **cloud escalation** row SHALL state plainly that it spends real money and sends data off-device and is budget-capped and audited. No Full Potential cost SHALL be hidden from the row that offers it.

#### Scenario: The Full Potential section is reachable on the AI page

- **WHEN** the user opens the Hub and selects the AI feature page
- **THEN** a Full Potential section shows the master toggle followed by the five sub-toggles (CPU lane, batched runtime, media generation, background autonomy, cloud escalation)

#### Scenario: Every sub-toggle discloses its cost inline

- **WHEN** the Full Potential section is shown
- **THEN** each sub-toggle row displays its RAM / heat / latency / dollar cost as an always-visible caption, with the media row stating it evicts chat (the assistant goes quiet while it paints) and the cloud row stating it spends real money and sends data off-device (budget-capped + audited)

#### Scenario: Toggling persists and is preserved by reset

- **WHEN** the user releases full potential and enables a sub-capability, then relaunches
- **THEN** the selections are restored, and a reset-to-defaults preserves them like the other AI opt-ins

### Requirement: The Full Potential sub-toggles are progressively enabled by the master

The Hub's Full Potential section SHALL gate the five sub-toggles behind the master: while the master `fullPotentialEnabled` is **off**, the five sub-toggles SHALL be shown but **disabled (visibly relocked)**, mirroring how a disabled feature's controls remain reachable but inert. Turning the master **off** SHALL relock all five sub-toggles in the UI while **retaining** their persisted values, so re-arming the master restores the prior selection rather than clearing it.

#### Scenario: Sub-toggles disabled until the master is on

- **WHEN** the Full Potential section is shown with the master off
- **THEN** the five sub-toggles appear disabled (visibly relocked) and cannot be changed until the master is turned on

#### Scenario: Panic-off relocks without clearing

- **WHEN** the user has the master and some sub-toggles on and turns the master off, then turns it back on
- **THEN** the sub-toggles relock while the master is off, and on re-arming the master the previously-enabled sub-toggles are restored to on (their values were retained, not cleared)

#### Scenario: A Full Potential persistence failure is non-blocking

- **WHEN** persisting or loading a Full Potential setting fails
- **THEN** the page surfaces a bounded, non-blocking message with a clean headline (details behind an opt-in disclosure) and the rest of the page stays usable, with no app-modal alert and no raw error text in the headline
