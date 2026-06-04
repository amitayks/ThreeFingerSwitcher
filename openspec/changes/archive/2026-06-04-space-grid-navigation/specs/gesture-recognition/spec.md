## ADDED Requirements

### Requirement: Vertical row stepping after activation
After the switcher has activated via horizontal motion, the system SHALL track vertical centroid travel and step the selection between Space-rows — one row each time accumulated vertical travel reaches the configured row-step distance (with carry), reversing when direction reverses. The system SHALL NOT track vertical for row stepping before activation, so a fresh vertical three-finger gesture still yields to the OS (Mission Control / App Exposé).

#### Scenario: Up/down switches Space-rows mid-gesture
- **WHEN** the overlay is active and the fingers move vertically past the row-step distance
- **THEN** the selection moves to the adjacent Space-row (and again for each further row-step distance)

#### Scenario: Fresh vertical still yields to the OS
- **WHEN** three fingers move vertically before any horizontal activation
- **THEN** the recognizer does not show the overlay and does not consume the vertical motion (the OS handles Mission Control / App Exposé)

#### Scenario: Horizontal jitter does not flip rows
- **WHEN** the user scrubs horizontally with small incidental vertical wobble below the row-step distance
- **THEN** no row change occurs

#### Scenario: Reverse vertical direction setting
- **WHEN** the reverse-vertical setting is enabled
- **THEN** sliding up moves rows in the opposite direction from the default
