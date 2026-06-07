# launcher-overlay Specification

## Purpose

Define the four-finger launcher overlay: activation on the home cell, item/context stepping, deterministic home-cell entry, dwell-to-arm with haptic and charge-ring feedback, lift-fires-only-when-armed semantics, and the context-band visual encoding.
## Requirements
### Requirement: Four-finger launcher activation
When the launcher opt-in is effective, a four-finger gesture whose horizontal travel crosses the four-finger activation threshold SHALL show the launcher overlay and place the selection on the deterministic home cell (the home band, home column). The overlay SHALL be a non-activating panel that never becomes key or steals focus, visible across all Spaces, consistent with the window switcher's overlay.

#### Scenario: Horizontal four-finger swipe opens the launcher
- **WHEN** the opt-in is effective and four fingers scrub horizontally past the activation threshold
- **THEN** the launcher overlay appears with the selection on the home cell

#### Scenario: Below threshold shows nothing
- **WHEN** four fingers move horizontally but never cross the activation threshold, then lift
- **THEN** no overlay is shown and nothing is fired

#### Scenario: Overlay does not steal focus
- **WHEN** the launcher overlay is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

### Requirement: Item stepping and context stepping
While the launcher overlay is active, horizontal travel SHALL step the selection between items within the current context band (one item per item-step distance, with carry), and vertical travel SHALL step the selection between context bands (one band per context-step distance, with carry). Stepping past the first/last item or band SHALL clamp (not wrap) unless wrap is configured.

#### Scenario: Horizontal steps items
- **WHEN** the overlay is active and the fingers move horizontally past the item-step distance
- **THEN** the selection moves to the adjacent item in the current band (and again per further item-step distance)

#### Scenario: Vertical steps context bands
- **WHEN** the overlay is active and the fingers move vertically past the context-step distance
- **THEN** the selection moves to the adjacent context band

#### Scenario: Selecting an empty edge clamps
- **WHEN** the selection is on the first item and the user steps backward
- **THEN** the selection stays on the first item (no wrap, by default)

### Requirement: Deterministic home-cell entry
The launcher SHALL always enter on the same home cell, independent of which item or band was used last. The selection order SHALL be the fixed user-defined order and SHALL NOT be reordered by recency or frequency.

#### Scenario: Entry is positionally stable
- **WHEN** the user fires an item, then later re-opens the launcher
- **THEN** the selection starts on the same home cell as before (not on the last-fired item)

### Requirement: Dwell-to-arm with feedback
Landing the selection on an item and holding it (no further stepping) for at least the configured dwell duration SHALL arm that item. Arming SHALL be signalled by a haptic tick (best-effort) and a visual charge-ring that fills over the dwell duration and locks when armed. Moving the selection to another item SHALL reset the dwell and disarm.

#### Scenario: Dwell arms the item
- **WHEN** the selection rests on an item for at least the dwell duration
- **THEN** the item becomes armed, a haptic tick fires (if available), and the charge-ring shows armed

#### Scenario: Charge-ring tracks partial dwell
- **WHEN** the selection has rested on an item for less than the dwell duration
- **THEN** the charge-ring is partially filled and the item is not armed

#### Scenario: Moving off disarms
- **WHEN** an item is armed and the user steps to another item
- **THEN** the previous item disarms, its ring empties, and the new item begins its own dwell

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

### Requirement: Context-band visual encoding
The launcher SHALL render each item as an icon plus a short label tinted/accented by its context band color, SHALL visually distinguish item kinds (e.g. a badge for presets, a marker for scripts), and SHALL show a band indicator (reusing the switcher's row-indicator gutter) colored per band.

#### Scenario: Bands are color-coded
- **WHEN** the overlay shows multiple context bands
- **THEN** each band and its indicator dot are shown in that band's configured color

#### Scenario: Presets are distinguishable
- **WHEN** an item is a preset
- **THEN** it is rendered with a badge that distinguishes it from single-action items

