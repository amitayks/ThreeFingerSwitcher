## ADDED Requirements

### Requirement: Launcher opt-in binds feature and four-finger native free
The system SHALL expose a single launcher opt-in, off by default, that binds together (a) the recognizer emitting four-finger launcher intents and (b) freeing the native four-finger horizontal and vertical swipe gestures. The two SHALL NOT be independently enabled: enabling requests both, and disabling reverts both. The opt-in SHALL persist across launches and be reachable from the Settings UI and surfaced during onboarding.

#### Scenario: Off by default
- **WHEN** the app runs for the first time
- **THEN** the launcher opt-in is off, four fingers do not open the launcher, and the native four-finger swipe gestures are untouched

#### Scenario: Enabling requests both sides together
- **WHEN** the user enables the launcher opt-in
- **THEN** the app frees the native four-finger swipe gestures (with consent) and enables four-finger launcher intents once the change is effective

#### Scenario: Disabling reverts both sides together
- **WHEN** the user disables the launcher opt-in
- **THEN** the app restores the native four-finger swipe values and the recognizer stops emitting launcher intents

#### Scenario: Opt-in persists across launches
- **WHEN** the user enables the launcher opt-in and relaunches the app
- **THEN** the opt-in remains enabled and is reapplied

### Requirement: Launcher tunables
The system SHALL expose tunable parameters for the launcher: a four-finger activation threshold, an item-step distance, a context-step distance, and a dwell-to-arm duration. All SHALL persist and appear in the Settings UI. These tunables SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Dwell duration default is brief but deliberate
- **WHEN** the app runs for the first time
- **THEN** the dwell-to-arm duration defaults to a brief deliberate value (on the order of half a second), not a full second

#### Scenario: Changing dwell changes arm time
- **WHEN** the launcher opt-in is enabled and the user increases the dwell-to-arm duration
- **THEN** an item must be rested on longer before it arms

#### Scenario: Changing context-step distance changes band sensitivity
- **WHEN** the launcher opt-in is enabled and the user increases the context-step distance
- **THEN** more vertical travel is required to switch context bands

#### Scenario: Launcher tunables persist
- **WHEN** the user changes a launcher tunable and relaunches
- **THEN** the value is retained and applied when the opt-in is enabled
