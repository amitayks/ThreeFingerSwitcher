## MODIFIED Requirements

### Requirement: Four-finger launcher gesture intents
When tracking a latched four-finger launcher gesture, the recognizer SHALL emit semantic launcher intents and SHALL NOT raise windows or step Space-rows: an activate intent when horizontal travel crosses the four-finger activation threshold; an item-step intent (with direction) per item-step distance of horizontal travel after activation; a context-step intent (with direction) per context-step distance of vertical travel after activation; and an end intent when the gesture ends. The recognizer SHALL NOT itself implement dwell, arm, or fire — those are owned by the launcher controller.

The launcher gesture SHALL be **latched** at begin and SHALL remain a launcher gesture for its entire lifetime regardless of later contact-count changes: a transient three-finger count (for example while lifting from four fingers to two) SHALL NOT route to the switcher and SHALL NOT cancel the gesture. After the four-finger activation, the gesture SHALL continue while **two or more** contacts remain, with item-step and context-step travel measured from the **centroid of the remaining contacts**. The step reference origin SHALL be **re-baselined on every contact-count change** (with any in-progress sub-step carry cleared) so that relaxing or adding fingers produces no step. The gesture SHALL **end when the contact count drops below two**, at which point the recognizer emits the end intent and the controller decides fire-or-dismiss. Keeping four fingers in contact for the whole gesture SHALL behave exactly as before.

#### Scenario: Activate on horizontal threshold
- **WHEN** a four-finger launcher gesture's horizontal travel crosses the activation threshold
- **THEN** the recognizer emits a launcher activate intent

#### Scenario: Item step on horizontal travel
- **WHEN** the launcher gesture is active and horizontal travel accumulates past the item-step distance
- **THEN** the recognizer emits an item-step intent in the travel direction

#### Scenario: Context step on vertical travel
- **WHEN** the launcher gesture is active and vertical travel accumulates past the context-step distance
- **THEN** the recognizer emits a context-step intent in the travel direction

#### Scenario: Navigation continues after dropping to two fingers
- **WHEN** the launcher gesture is active and the user lifts to two (or three) fingers and then moves
- **THEN** the gesture stays a launcher gesture and the recognizer emits item/context-step intents from the remaining contacts' movement

#### Scenario: Relaxing fingers does not emit a spurious step
- **WHEN** the contact count changes (e.g. four fingers relax to two) and the centroid shifts as fingers leave
- **THEN** the step reference origin is re-baselined and no item-step or context-step intent is emitted from the count change alone

#### Scenario: Transient three-finger count does not route to the switcher
- **WHEN** an active four-finger launcher gesture passes through a three-finger count while lifting toward two
- **THEN** the recognizer emits no switcher intents and does not cancel the launcher gesture

#### Scenario: End below two contacts
- **WHEN** the contact count drops below two during a launcher gesture
- **THEN** the recognizer emits a launcher end intent and the controller decides fire-or-dismiss

## REMOVED Requirements

### Requirement: Anchored positional navigation interpretation
**Reason**: Reverting to the v0.11.0 odometer model. Post-activation navigation no longer anchors a center/footprint scale or interprets movement as offset-from-center; the per-axis padding-box / out-and-back zone machine, the held-in-zone sign, the footprint fallback, and the pull-back-to-recenter behavior are all removed.
**Migration**: Post-activation launcher navigation reverts to **accumulated signed centroid travel with carry** (see *Four-finger launcher gesture intents*), and auto-repeat reverts to the **physical-edge-held** signal driving the controller's edge-triggered auto-repeat (see launcher-overlay *Edge-triggered auto-repeat for all launcher navigation*). The same odometer interpretation applies to the Files column navigator and the Media player transport sub-states. The origin is re-baselined on every contact-count change exactly as before.

### Requirement: Directional axis-lock commits a stroke to one axis
**Reason**: The directional axis-lock (commit wedge, per-axis re-anchor, re-commit hysteresis, L-shaped moves) is a property of the positional model being removed; the odometer model accumulates both axes independently with no single-axis commitment.
**Migration**: None. Under the restored odometer, both axes accumulate travel independently and emit steps per their own step distance; there is no axis-lock, no commit wedge, and no re-commit. Diagonal strokes step both axes as the travel warrants.

### Requirement: Directional (asymmetric) commit wedge
**Reason**: The asymmetric rightward crossing wedge exists only to tune the positional axis-lock's rail→items crossing, which no longer exists.
**Migration**: None. The band-rail ⇄ grid crossing under the odometer is driven by horizontal travel accumulation exactly as in v0.11.0; there is no wedge to widen.
