## MODIFIED Requirements

### Requirement: Lift fires only when armed
Lifting the fingers SHALL fire the currently armed item; if no item is armed, lifting SHALL dismiss the overlay without firing anything. A quick scrub-and-lift (no dwell) SHALL therefore never fire an item. The overlay SHALL be ordered out **before** the armed item is fired, so an action that switches Spaces (e.g. Next/Previous Space) does not carry the still-visible overlay onto the destination Space (the panel can join all Spaces, so firing first would leave it lingering there).

#### Scenario: Armed lift fires
- **WHEN** an item is armed and the fingers lift
- **THEN** that item is fired and the overlay hides

#### Scenario: Unarmed lift dismisses
- **WHEN** the fingers lift while no item is armed
- **THEN** the overlay hides and nothing is fired

#### Scenario: Regret path
- **WHEN** an item is armed and the user keeps swiping off it, then lifts
- **THEN** nothing is fired and the overlay hides

#### Scenario: Space-switch action does not drag the overlay along
- **WHEN** an armed Next/Previous Space item is fired on lift
- **THEN** the overlay is dismissed before the Space switch, and it does not appear on the destination Space
