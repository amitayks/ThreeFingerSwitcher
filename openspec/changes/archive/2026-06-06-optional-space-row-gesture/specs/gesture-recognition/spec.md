## MODIFIED Requirements

### Requirement: Vertical row stepping after activation
After the switcher has activated via horizontal motion AND the Space-row switching opt-in is effectively enabled, the system SHALL track vertical centroid travel and step the selection between Space-rows — one row each time accumulated vertical travel reaches the configured row-step distance (with carry), reversing when direction reverses. When the opt-in is not effectively enabled, the system SHALL NOT track vertical for row stepping at any point in the gesture and SHALL fully yield vertical motion to the OS (Mission Control / App Exposé). In all cases the system SHALL NOT track vertical for row stepping before horizontal activation.

#### Scenario: Up/down switches Space-rows mid-gesture when enabled
- **WHEN** the Space-row switching opt-in is effectively enabled, the overlay is active, and the fingers move vertically past the row-step distance
- **THEN** the selection moves to the adjacent Space-row (and again for each further row-step distance)

#### Scenario: Vertical fully yielded when the opt-in is disabled
- **WHEN** the Space-row switching opt-in is not effectively enabled and the fingers move vertically after horizontal activation
- **THEN** the recognizer takes no row action and does not consume the vertical motion, leaving the OS to handle Mission Control / App Exposé

#### Scenario: Fresh vertical yields to the OS when the feature is off
- **WHEN** three fingers move vertically before any horizontal activation and the Space-row switching opt-in is not effectively enabled
- **THEN** the recognizer does not show the overlay and does not consume the vertical motion (the OS handles Mission Control / App Exposé natively)

#### Scenario: Horizontal jitter does not flip rows
- **WHEN** the opt-in is effectively enabled and the user scrubs horizontally with small incidental vertical wobble below the row-step distance
- **THEN** no row change occurs

#### Scenario: Reverse vertical direction setting
- **WHEN** the opt-in is effectively enabled and the reverse-vertical setting is enabled
- **THEN** sliding up moves rows in the opposite direction from the default

## ADDED Requirements

### Requirement: Fresh vertical triggers Mission Control / App Exposé when the feature owns the gesture
When the Space-row switching opt-in is effectively enabled (so the OS three-finger vertical gesture has been freed to a scroll), a fresh three-finger vertical swipe — vertical axis dominant, before any horizontal activation — SHALL emit a one-shot Mission Control / App Exposé intent rather than yielding, so idle three-finger up/down still opens the system overview even though the OS no longer handles it. Up SHALL map to Mission Control and down to App Exposé, the intent SHALL fire at most once per gesture, and only after a deliberate vertical travel threshold (larger than axis detection) to avoid accidental triggers.

#### Scenario: Idle vertical up opens Mission Control
- **WHEN** the opt-in is effectively enabled and three fingers swipe up past the trigger threshold without a prior horizontal activation
- **THEN** the recognizer emits a single Mission Control intent (up) and shows no overlay

#### Scenario: Idle vertical down opens App Exposé
- **WHEN** the opt-in is effectively enabled and three fingers swipe down past the trigger threshold without a prior horizontal activation
- **THEN** the recognizer emits a single App Exposé intent (down)

#### Scenario: Fires once per gesture
- **WHEN** the fingers continue moving vertically after the intent has fired
- **THEN** no further Mission Control / App Exposé intent is emitted until the fingers lift and a new gesture begins

#### Scenario: Below threshold does not trigger
- **WHEN** the opt-in is effectively enabled and the vertical travel stays below the trigger threshold
- **THEN** no Mission Control / App Exposé intent is emitted
