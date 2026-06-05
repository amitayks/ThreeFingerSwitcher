## MODIFIED Requirements

### Requirement: Vertical row stepping after activation
After the switcher has activated via horizontal motion AND the Space-row switching opt-in is effectively enabled, the system SHALL track vertical centroid travel and step the selection between Space-rows — one row each time accumulated vertical travel reaches the configured row-step distance (with carry), reversing when direction reverses. When the opt-in is not effectively enabled, the system SHALL NOT track vertical for row stepping at any point in the gesture and SHALL fully yield vertical motion to the OS (Mission Control / App Exposé). In all cases the system SHALL NOT track vertical for row stepping before horizontal activation.

#### Scenario: Up/down switches Space-rows mid-gesture when enabled
- **WHEN** the Space-row switching opt-in is effectively enabled, the overlay is active, and the fingers move vertically past the row-step distance
- **THEN** the selection moves to the adjacent Space-row (and again for each further row-step distance)

#### Scenario: Vertical fully yielded when the opt-in is disabled
- **WHEN** the Space-row switching opt-in is not effectively enabled and the fingers move vertically after horizontal activation
- **THEN** the recognizer takes no row action and does not consume the vertical motion, leaving the OS to handle Mission Control / App Exposé

#### Scenario: Fresh vertical still yields to the OS
- **WHEN** three fingers move vertically before any horizontal activation
- **THEN** the recognizer does not show the overlay and does not consume the vertical motion (the OS handles Mission Control / App Exposé)

#### Scenario: Horizontal jitter does not flip rows
- **WHEN** the opt-in is effectively enabled and the user scrubs horizontally with small incidental vertical wobble below the row-step distance
- **THEN** no row change occurs

#### Scenario: Reverse vertical direction setting
- **WHEN** the opt-in is effectively enabled and the reverse-vertical setting is enabled
- **THEN** sliding up moves rows in the opposite direction from the default
