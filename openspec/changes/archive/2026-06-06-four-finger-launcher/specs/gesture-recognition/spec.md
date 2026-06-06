## MODIFIED Requirements

### Requirement: Three-finger gesture detection
The system SHALL latch the active finger count at the start of a candidate gesture and use it to route the whole gesture. A gesture beginning with exactly three fingers SHALL be tracked as a window-switcher gesture. When the launcher opt-in is effective, a gesture beginning with four fingers SHALL be tracked as a launcher gesture. The latched count SHALL govern the gesture for its lifetime, with the same brief-excursion debounce used for edge flicker. When the launcher opt-in is NOT effective, a fourth finger landing during a three-finger candidate SHALL cancel it (preserving prior behavior).

#### Scenario: Exactly three fingers starts switcher tracking
- **WHEN** the active finger count becomes exactly 3
- **THEN** the recognizer captures the starting centroid and begins tracking displacement in window-switcher mode

#### Scenario: Four fingers starts launcher tracking
- **WHEN** the launcher opt-in is effective and a gesture begins with four fingers
- **THEN** the recognizer tracks displacement in launcher mode for the duration of the gesture

#### Scenario: Fourth finger cancels when the launcher is off
- **WHEN** the launcher opt-in is not effective and a fourth finger lands during a three-finger candidate or active gesture
- **THEN** the recognizer cancels without committing and hides any overlay

## ADDED Requirements

### Requirement: Four-finger launcher gesture intents
When tracking a latched four-finger launcher gesture, the recognizer SHALL emit semantic launcher intents and SHALL NOT raise windows or step Space-rows: an activate intent when horizontal travel crosses the four-finger activation threshold; an item-step intent (with direction) per item-step distance of horizontal travel after activation; a context-step intent (with direction) per context-step distance of vertical travel after activation; and an end intent when the fingers lift. The recognizer SHALL NOT itself implement dwell, arm, or fire — those are owned by the launcher controller.

#### Scenario: Activate on horizontal threshold
- **WHEN** a four-finger launcher gesture's horizontal travel crosses the activation threshold
- **THEN** the recognizer emits a launcher activate intent

#### Scenario: Item step on horizontal travel
- **WHEN** the launcher gesture is active and horizontal travel accumulates past the item-step distance
- **THEN** the recognizer emits an item-step intent in the travel direction

#### Scenario: Context step on vertical travel
- **WHEN** the launcher gesture is active and vertical travel accumulates past the context-step distance
- **THEN** the recognizer emits a context-step intent in the travel direction

#### Scenario: End on lift
- **WHEN** the fingers lift during a launcher gesture
- **THEN** the recognizer emits a launcher end intent and the controller decides fire-or-dismiss
