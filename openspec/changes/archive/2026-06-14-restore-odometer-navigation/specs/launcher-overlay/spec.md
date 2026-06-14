## MODIFIED Requirements

### Requirement: Item stepping and context stepping
While the launcher overlay is active, navigation SHALL be a 2D cursor split across the band list (left) and the content grid (right), with the per-axis behavior below:

- With the **band list focused**, **vertical** travel SHALL switch the active band (one band per context-step distance — a *deliberate* step, with carry), and **horizontal** travel toward the content SHALL cross the focus into the grid, landing on the band's home/first item. Horizontal travel away from the content SHALL clamp (there is nothing to the left of the band list).
- With the **grid focused**, **horizontal** travel SHALL step the selection between items within the current row (one item per item-step distance, with carry); from the **first column**, a further step toward the band list SHALL cross the focus back to the band list. **Vertical** travel SHALL step between grid rows and SHALL clamp at the first and last row (it no longer rises to a separate header row — the bands are reached horizontally now).

Stepping past the first/last band or item SHALL clamp (not wrap) unless wrap is configured.

The **Clipboard band** is an exception to the grid's horizontal mapping. Its content is a single-column master-detail list (key list + value preview): horizontal travel toward the content crosses into the **key list**, vertical travel scrubs between entries (rows), and horizontal travel within the key list is repurposed for pin / return-to-band-list (see the Clipboard band navigation requirement) rather than stepping items.

#### Scenario: Vertical switches bands on the band list
- **WHEN** the band list is focused and the fingers move vertically past the context-step distance
- **THEN** the active band changes to the adjacent band (and again per further context-step distance), the content pane updates to that band, and the active band's icon is highlighted

#### Scenario: Horizontal crosses from the band list into the grid
- **WHEN** the band list is focused and the fingers move horizontally toward the content past the item-step distance
- **THEN** the focus crosses into the grid, landing on the band's first/home item (now armable)

#### Scenario: Horizontal steps items within a row
- **WHEN** the grid is focused on a normal band and the fingers move horizontally past the item-step distance (not at the first column moving outward)
- **THEN** the selection moves to the adjacent item in the current row (and again per further item-step distance)

#### Scenario: Horizontal from the first column returns to the band list
- **WHEN** the grid is focused with the selection in the first column and the fingers move horizontally toward the band list
- **THEN** the focus crosses back to the band list at the active band's icon

#### Scenario: Vertical steps grid rows and clamps at the edges
- **WHEN** the grid is focused and the fingers move vertically past the item-step distance
- **THEN** the selection moves to the adjacent row, clamping at the first and last row (it does not rise onto the band list)

#### Scenario: Selecting an empty edge clamps
- **WHEN** the selection is on the first item and the user steps backward within the row
- **THEN** the selection stays on the first item (no wrap, by default)

#### Scenario: Clipboard band overrides horizontal item stepping
- **WHEN** the grid is focused on the Clipboard band and the fingers move horizontally within the key list
- **THEN** the selection does not step to another entry; instead the pin / return-to-band-list behavior applies

### Requirement: Edge-triggered auto-repeat for all launcher navigation

While the launcher is active, holding the controlling contact at a trackpad edge SHALL **auto-repeat** the corresponding navigation step, on **both axes**: the vertical edges repeat vertical stepping (switching bands when the band list is focused, or moving between grid rows / the Clipboard list when the grid is focused), and the horizontal edges repeat horizontal stepping (moving the item cursor within the grid, or crossing between the band list and the grid). Auto-repeat SHALL **accelerate** the longer an edge is held. It SHALL apply to every band's navigation, not only overflowing lists — a step that has nowhere to go SHALL simply clamp.

In the **Clipboard band**, horizontal auto-repeat SHALL be suppressed (there horizontal is the deliberate pin / return-to-band-list action), while vertical auto-repeat still applies. In the **Files navigator**, auto-repeat SHALL apply on **both axes** — vertical (highlight) and horizontal (depth) — so holding depth at the edge **auto-drills** through the directory tree, exactly like every other navigation axis. A clamped step (one that does not move the selection) SHALL NOT reset the dwell, so holding at an edge with nothing further to reach still lets the current item arm and fire. Detection SHALL use hysteresis (enter < exit) so jitter at the boundary does not flap. The edge zone, base rate, acceleration, and maximum rate SHALL be tunable.

#### Scenario: Holding at a vertical edge keeps switching bands or stepping rows
- **WHEN** the user scrubs to the end of finger travel at the bottom (or top) trackpad edge
- **THEN** the active band keeps switching (band list focused) or the row selection keeps advancing (grid focused) without lifting, accelerating the longer the edge is held

#### Scenario: Holding at a horizontal edge keeps stepping items
- **WHEN** the grid is focused and the contact is held at the right/left edge
- **THEN** the item cursor keeps moving in that direction, accelerating, until it clamps (or crosses to the band list at the left edge)

#### Scenario: Clipboard band suppresses horizontal auto-repeat
- **WHEN** the Clipboard band is active and the contact is held at a horizontal edge
- **THEN** no pin / return-to-band-list action auto-repeats (only vertical auto-repeat applies there)

#### Scenario: Files navigator auto-drills depth at the horizontal edge
- **WHEN** the Files navigator is active and the contact is held at a horizontal edge
- **THEN** depth descend/ascend auto-repeats (auto-drills), accelerating the longer the edge is held, just like the highlight axis at a vertical edge

#### Scenario: A clamped edge does not block arming
- **WHEN** the selection is already at the end in the held direction and the contact stays at that edge
- **THEN** the auto-repeat is a no-op that does not reset the dwell, so the current item can still arm and fire

#### Scenario: Leaving the edge stops auto-repeat
- **WHEN** the contact moves back off the edge or lifts
- **THEN** auto-repeat stops

## REMOVED Requirements

### Requirement: Single-axis launcher navigation across the rail↔grid crossing
**Reason**: This requirement specifies the positional directional axis-lock behavior at the band-rail ⇄ grid crossing (committed axis, per-axis re-anchor on cross, diagonal-drift forgiveness), which is removed with the positional model.
**Migration**: Under the restored odometer, the rail ⇄ grid crossing is driven by accumulated horizontal travel and band switching by accumulated vertical travel, independently and with carry — exactly as in v0.11.0. There is no single-axis commitment; a diagonal stroke advances both axes as the travel warrants.

### Requirement: Wider acceptance for crossing from the band rail into the items
**Reason**: The wider rightward "crossing wedge" only tunes the positional axis-lock's rail→items commitment, which no longer exists.
**Migration**: None. Crossing from the band rail into the items happens whenever accumulated horizontal travel toward the content crosses the item-step distance.
