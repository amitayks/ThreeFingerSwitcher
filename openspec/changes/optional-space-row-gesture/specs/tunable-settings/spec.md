## ADDED Requirements

### Requirement: Space-row switching opt-in binds feature and system change
The system SHALL expose a single "Space-row switching" opt-in, off by default, that binds together (a) the recognizer's vertical row stepping and (b) the relocation of the native three-finger vertical gesture to four fingers. The two SHALL NOT be independently enabled: turning the opt-in on requests both, and turning it off reverts both. The opt-in SHALL persist across launches and be reachable from the Settings UI and surfaced during onboarding.

#### Scenario: Off by default
- **WHEN** the app runs for the first time
- **THEN** Space-row switching is off, the recognizer does not perform row stepping, and the native three-finger vertical gesture is left untouched

#### Scenario: Enabling requests both sides together
- **WHEN** the user enables Space-row switching
- **THEN** the app relocates the native three-finger vertical gesture to four fingers (with consent) and enables vertical row stepping once that relocation is effective

#### Scenario: Disabling reverts both sides together
- **WHEN** the user disables Space-row switching
- **THEN** the app restores the original vertical trackpad values and the recognizer stops performing row stepping

#### Scenario: Opt-in persists across launches
- **WHEN** the user enables Space-row switching and relaunches the app
- **THEN** the opt-in remains enabled and is reapplied

## MODIFIED Requirements

### Requirement: Vertical row-switching tunables
The system SHALL expose tunable parameters for vertical Space-row switching: a row-step distance (vertical travel per row step, defaulting larger than the horizontal step distance) and a reverse-vertical-direction toggle. Both SHALL persist and appear in the Settings UI. These tunables SHALL take effect only while the Space-row switching opt-in is enabled; when the opt-in is off they have no behavioral effect because no row stepping occurs.

#### Scenario: Row-step distance defaults larger than horizontal step
- **WHEN** the app runs for the first time
- **THEN** the row-step distance default is larger than the horizontal step distance so rows are harder to trigger than window steps

#### Scenario: Changing row-step distance changes row sensitivity
- **WHEN** the Space-row switching opt-in is enabled and the user increases the row-step distance
- **THEN** more vertical travel is required to switch Space-rows

#### Scenario: Reverse vertical persists
- **WHEN** the user toggles reverse-vertical and relaunches
- **THEN** the setting is retained and applied when the opt-in is enabled

#### Scenario: Tunables inert while opt-in is off
- **WHEN** the Space-row switching opt-in is off
- **THEN** changing the row-step distance or reverse-vertical setting produces no row stepping
