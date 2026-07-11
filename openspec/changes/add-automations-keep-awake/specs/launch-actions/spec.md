## ADDED Requirements

### Requirement: Firing an automation item toggles its mode
When an automation launch item is fired, the system SHALL **toggle** the corresponding automation rather than run a one-shot effect: start it if its mode is inactive, stop it if already active. This differs from every other item kind, which completes on the firing lift. The toggle SHALL be routed out of the fire dispatch through an injected seam (mirroring the AI-command hand-off) so the launcher's firing layer stays decoupled from the automation's stateful owner.

#### Scenario: First fire starts, second fire stops
- **WHEN** an automation item is fired while its mode is inactive
- **THEN** the automation starts

- **WHEN** the same automation item is fired again while its mode is active
- **THEN** the automation stops

#### Scenario: Automation firing is not a one-shot completion
- **WHEN** an automation item is fired
- **THEN** it enters/leaves a persistent mode owned outside the launcher, rather than performing a single immediate effect that ends on the lift
