## MODIFIED Requirements

### Requirement: Lift fires only when armed
Lifting the fingers SHALL fire the currently armed item; if no item is armed, lifting SHALL dismiss the overlay without firing anything. A quick scrub-and-lift (no dwell) SHALL therefore never fire an item. The overlay SHALL be ordered out **before** the armed item is fired, so an action that switches Spaces (e.g. Next/Previous Space) does not carry the still-visible overlay onto the destination Space (the panel can join all Spaces, so firing first would leave it lingering there).

An **AI command item** is an exception to the order-out-before-fire rule: firing it does NOT dismiss the overlay. Instead, firing **begins the command and opens its streaming preview canvas**, leaving the overlay visible; the command then resolves through the AI command preview-and-commit behavior (a fresh four-finger **down** swipe commits, a fresh four-finger **horizontal** swipe discards) rather than completing on this first lift. Because the firing lift has already raised the fingers, the canvas is resolved by a *new* swipe, never by re-lifting; a stray lift while the canvas is open is a no-op. The order-out-before-fire rule continues to apply to items that complete on lift (launches, Space switches, paste-on-fire).

A **screen-region (vision) command** is a further exception **within** the AI-command exception: because it must reveal the desktop so the user can designate a region, firing it **does** order the overlay out first (like a completing action), then presents the interactive region picker. The streaming preview canvas opens only **after** a region is captured, and the command then resolves through the normal preview-and-commit behavior. If the picker is **cancelled** (a click without a drag), no canvas opens, nothing is generated, and the captured front app is restored.

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

#### Scenario: Armed AI command lift opens the preview canvas
- **WHEN** an armed AI command item is lifted
- **THEN** the command begins, the overlay stays visible, and its streaming preview canvas appears instead of the overlay dismissing

#### Scenario: Armed screen-region command dismisses the overlay then picks
- **WHEN** an armed screen-region (vision) AI command item is lifted
- **THEN** the overlay is dismissed, the interactive region picker is presented over the revealed desktop, and the preview canvas opens only after a region is captured

#### Scenario: Cancelled region pick opens no canvas
- **WHEN** the region picker is cancelled by a click without a drag
- **THEN** no preview canvas opens, nothing is generated, and the captured front app is restored
