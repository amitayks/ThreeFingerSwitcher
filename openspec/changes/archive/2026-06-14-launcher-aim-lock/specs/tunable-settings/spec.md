## ADDED Requirements

### Requirement: Axis-lock tunables

The system SHALL expose tunable parameters, with sensible defaults, for the directional axis-lock, persisted and live-applied:

- a **commit wedge** — how strongly one axis must dominate the other before a stroke commits to it (the diagonal-drift forgiveness; a larger wedge forgives more off-axis drift), expressed as a ratio or half-angle;
- a **crossing wedge** — a **wider** acceptance half-angle applied to the band-rail → items crossing (the rightward, into-items direction), so an off-axis nudge toward the items enters them rather than switching a band (the "bigger crossing triangle"); larger than the commit wedge;
- a **re-commit hysteresis** — how far the perpendicular axis must exceed the committed axis before the lock switches to it (preventing accidental axis switching from incidental drift).

These tunables SHALL be surfaced on the Hub Launcher page and SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Defaults forgive normal off-axis drift

- **WHEN** the app runs for the first time and the user strokes roughly along an axis with incidental drift
- **THEN** the default commit wedge commits to the intended axis without changing the perpendicular one

#### Scenario: Widening the wedge forgives larger drift

- **WHEN** the user increases the commit wedge
- **THEN** a more steeply-angled stroke still commits to the dominant axis rather than splitting across both

#### Scenario: Widening the crossing wedge eases entering the items

- **WHEN** the user increases the crossing wedge
- **THEN** a more steeply up/down-and-right stroke from the band rail still enters the items rather than switching a band

#### Scenario: Hysteresis prevents accidental axis switching

- **WHEN** the user increases the re-commit hysteresis and then drifts slightly off the committed axis
- **THEN** the lock stays on the committed axis until a clearly deliberate perpendicular turn

#### Scenario: Axis-lock tunables persist and live-apply

- **WHEN** the user changes an axis-lock tunable while the launcher opt-in is enabled
- **THEN** the new value is applied to the next navigation without restart and is retained across relaunch
