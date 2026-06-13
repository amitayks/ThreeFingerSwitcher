## ADDED Requirements

### Requirement: Player modal sub-state owns the trackpad
The recognizer SHALL support a sustained **player modal sub-state** that, while active, routes all touch frames to player transport interpretation before the three-/four-finger latch — mirroring the existing files-drill and canvas-resolution modal bypasses, which run as the first statements of frame processing. While the player sub-state is active the recognizer SHALL NOT emit switcher or launcher intents (a three-finger count SHALL be interpreted as the player action-menu posture, never as the window switcher). The controller SHALL own entering and exiting the sub-state; entering SHALL seed a fresh tracking session. The player transport intents SHALL be new delegate methods with default no-op implementations so existing delegates remain valid.

#### Scenario: Player sub-state bypasses the finger-count latch
- **WHEN** the player sub-state is active and any touch frame arrives
- **THEN** the recognizer routes it to player transport interpretation and emits no switcher or launcher intents

#### Scenario: Three fingers in the player do not activate the switcher
- **WHEN** the player sub-state is active and a three-finger count is present
- **THEN** the recognizer treats it as the action-menu posture and does not activate the window switcher

#### Scenario: Entering seeds a fresh session
- **WHEN** the controller activates the player sub-state
- **THEN** a fresh tracking session is seeded (prior offsets/anchors cleared)

### Requirement: Player transport intents from the anchored-positional model
While the player sub-state is active, the recognizer SHALL emit player transport intents derived from the anchored-positional navigation model: a seek intent (with direction) on a two-finger horizontal outer-threshold crossing; a volume intent (with direction) on a two-finger vertical outer-threshold crossing; a play/pause-toggle intent on a two-finger tap with no navigation excursion; an action-menu intent on the relative one-finger-more posture (a finger added relative to the two-finger baseline, not an absolute count); a select intent when a lift resolves the open action menu; and a dismiss intent on a four-finger gesture. The recognizer SHALL emit a held-in-zone signal (with sign) on both the horizontal and vertical axes so the controller can auto-repeat seek and volume on both axes. The anchor SHALL be re-baselined on every contact-count change so a leaving or added finger emits no phantom transport intent.

#### Scenario: Two-finger horizontal emits a seek intent
- **WHEN** the player sub-state is active and a two-finger horizontal offset crosses the outer threshold
- **THEN** the recognizer emits one seek intent in that direction and signals held-in-zone while the offset is held

#### Scenario: Two-finger vertical emits a volume intent
- **WHEN** the player sub-state is active and a two-finger vertical offset crosses the outer threshold
- **THEN** the recognizer emits one volume intent in that direction and signals held-in-zone while the offset is held

#### Scenario: Two-finger tap emits play/pause toggle
- **WHEN** the player sub-state is active and two fingers touch and lift without crossing the inner deadzone
- **THEN** the recognizer emits a play/pause-toggle intent

#### Scenario: Relative +1 finger emits the action-menu intent
- **WHEN** the player sub-state is active and the user adds one finger relative to the two-finger baseline
- **THEN** the recognizer emits an action-menu intent (independent of the absolute finger count)

#### Scenario: Contact-count change emits no phantom intent
- **WHEN** the player sub-state is active and the contact count changes (a finger leaves or is added)
- **THEN** the anchor is re-baselined and no seek, volume, or toggle intent is emitted from the count change alone

#### Scenario: Four fingers emit dismiss
- **WHEN** the player sub-state is active and a four-finger gesture is made
- **THEN** the recognizer emits a player dismiss intent
