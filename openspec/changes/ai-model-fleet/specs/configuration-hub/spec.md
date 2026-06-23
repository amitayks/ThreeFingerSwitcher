## ADDED Requirements

### Requirement: AI page presents the model fleet roster with honest residency cost

The Hub's **AI** page SHALL present the model picker as a **fleet roster** in which each member shows its role (Chat / Ternary / Image / Video / Cloud), its compute lane (GPU / CPU / Cloud), its provider, the existing per-model on-disk / resident status (reflecting the currently selected member's own state, not a single global status), and its **honest residency cost** (its resident footprint in gigabytes). A member whose admission would **evict the chat model** SHALL disclose that consequence **inline, in the same breath it offers selection**, computed from the residency plan rather than hard-coded — for example, "selecting Video pauses the chat model; it reloads when generation finishes." A registry containing only the single chat descriptor (a fleet-of-one) SHALL render as today's single model picker.

#### Scenario: The roster shows each member's role, lane, and cost
- **WHEN** the user opens the AI page with a multi-member fleet
- **THEN** each member is listed with its role, lane, provider, its own on-disk/resident status, and its residency cost in gigabytes

#### Scenario: An evicting member discloses the cost inline
- **WHEN** the user views a fleet member whose admission the residency plan says would evict the chat model (a video or full-precision image model)
- **THEN** that member's row states that selecting it pauses the chat model and that chat reloads when generation finishes, and a member that co-resides (a Q4 image model) shows no such warning

#### Scenario: A fleet-of-one is unchanged
- **WHEN** only the chat descriptor is registered
- **THEN** the AI page renders the existing single model picker with its per-model lifecycle status, unchanged

### Requirement: Cloud fleet members are badged, cost-disclosed, and gated off by default

The Hub's **AI** page SHALL show each cloud fleet member (Claude, GLM-5.2) with a **Cloud** badge, its escalation cost (per-call $ and per-day budget cap), and SHALL render it **disabled with an explanatory caption** until cloud escalation is enabled (the cloud-escalation toggle, itself under the master full-potential gate). No cloud member SHALL be selectable, and no spend SHALL be implied, while the cloud tier is off. Any admission or escalation failure SHALL surface as a **bounded, non-blocking** row (a clean headline via the single error translator, opt-in copyable details, and a Retry affordance) — never an app-modal alert and never raw error text in a headline.

#### Scenario: Cloud members are disabled and captioned until enabled
- **WHEN** the user opens the AI page while cloud escalation is disabled
- **THEN** the cloud members show a Cloud badge and their escalation cost, are disabled, and carry a caption explaining they require enabling cloud escalation

#### Scenario: Enabling cloud makes the members selectable
- **WHEN** the user enables cloud escalation
- **THEN** the cloud members become selectable, still showing their per-call $ and per-day budget cost

#### Scenario: A fleet failure is bounded and non-blocking
- **WHEN** admitting or escalating to a fleet member fails
- **THEN** the AI page shows a bounded, non-blocking row with a clean headline, opt-in copyable details, and Retry — not a modal alert and not raw error text in the headline
