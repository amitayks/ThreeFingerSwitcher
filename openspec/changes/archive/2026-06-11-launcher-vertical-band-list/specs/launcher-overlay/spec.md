## ADDED Requirements

### Requirement: Vertical band list with a side content pane

The launcher SHALL render the context bands as a vertical list of band **icons on the left** (icons only — never the band names) and the active band's content (the icon grid, or the Clipboard master-detail) on the **right**, replacing the previous horizontal tab row above the grid. Each band's icon SHALL be **user-configurable** (the same icon picker as items), the **Clipboard** band SHALL use a dedicated preset icon, and a newly created band SHALL start with a default icon (not a default name). The icons SHALL sit at a **fixed small spacing**, vertically centered in the column (not spread to fill it). Only the **active** (highlighted) band's icon SHALL be drawn in that band's color; the other icons SHALL be colorless until they become active. When more than one band exists the band list SHALL be shown; when exactly one band exists the band list SHALL be omitted and only the content pane shown.

The **left band column** SHALL be a fixed-width icon strip. The launcher **window height** SHALL be driven **solely by the active band's item rows** — a two-row band is exactly two rows tall, a three-row band three — clamped to a minimum and maximum, where the maximum fits the full visible-row cap. Each item row SHALL reserve room for its **item title** so labels are not clipped, and a band of up to the visible-row cap SHALL fit **without internal scrolling**; only beyond that cap SHALL the content grid scroll, keeping the selected item visible.

#### Scenario: Multiple bands show the icon list on the left
- **WHEN** the launcher is shown with more than one band
- **THEN** a vertical list of band icons (not names) appears on the left and the active band's content fills the pane on the right

#### Scenario: A single band shows only the content
- **WHEN** the launcher is shown with exactly one band
- **THEN** no band list is rendered and only the content pane (the icon grid) is shown

#### Scenario: Only the active band's icon is colored
- **WHEN** the band list is shown
- **THEN** the icons sit at a fixed small spacing centered in the column, the active band's icon is drawn in its band color, and the rest are colorless until selected

#### Scenario: Up to the row cap fits without scrolling
- **WHEN** the active band has N item rows, N within the visible-row cap
- **THEN** the window is exactly N rows tall (each row reserving its item title) with no internal scroll, and switching to another band with the same row count does not change the window height

#### Scenario: Beyond the row cap the grid scrolls
- **WHEN** the active band has more item rows than the visible-row cap
- **THEN** the window height is clamped at the cap and the content grid scrolls (keeping the selected item visible)

## MODIFIED Requirements

### Requirement: Four-finger launcher activation
When the launcher opt-in is effective, a four-finger gesture whose horizontal travel crosses the four-finger activation threshold SHALL show the launcher overlay. When more than one band exists, the overlay SHALL place focus on the **band list at the home band's icon**, with no item armed; when exactly one band exists, the overlay SHALL place the selection on the deterministic home cell (the home column of the single band), armable immediately. The overlay SHALL be a non-activating panel that never becomes key or steals focus, visible across all Spaces, consistent with the window switcher's overlay.

#### Scenario: Horizontal four-finger swipe opens the launcher on the home band icon
- **WHEN** the opt-in is effective, more than one band exists, and four fingers scrub horizontally past the activation threshold
- **THEN** the launcher overlay appears with focus on the home band's icon and nothing armed

#### Scenario: Single-band launcher opens on the home cell
- **WHEN** the opt-in is effective, exactly one band exists, and four fingers scrub horizontally past the activation threshold
- **THEN** the launcher overlay appears with the selection on the home cell of that band (no band list shown)

#### Scenario: Below threshold shows nothing
- **WHEN** four fingers move horizontally but never cross the activation threshold, then lift
- **THEN** no overlay is shown and nothing is fired

#### Scenario: Overlay does not steal focus
- **WHEN** the launcher overlay is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

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

### Requirement: Deterministic home-cell entry
The launcher SHALL always enter at the same deterministic place, independent of which item or band was used last: the **home band's icon** (band list focused) when more than one band exists, or the **home cell** (home column) when a single band exists. The band order and item order SHALL be the fixed user-defined order and SHALL NOT be reordered by recency or frequency.

#### Scenario: Entry is positionally stable
- **WHEN** the user fires an item, then later re-opens the launcher
- **THEN** focus starts on the same home band icon (or, for a single band, the same home cell) as before — not on the last-used band or last-fired item

### Requirement: Context-band visual encoding
The launcher SHALL render the band strip as a **vertical list of band icons on the left** (icons only, never names), with the **active** band's icon drawn in its band color and the rest colorless. It SHALL render each item as an icon plus a short label tinted/accented by its context band color, and SHALL visually distinguish item kinds (e.g. a badge for presets, a marker for scripts). Each band's icon is user-configurable; the Clipboard band uses a dedicated preset icon.

#### Scenario: The active band's icon is colored in the vertical list
- **WHEN** the overlay shows multiple context bands
- **THEN** the bands appear as a vertical list of icons on the left and only the active band's icon is drawn in its band color

#### Scenario: Presets are distinguishable
- **WHEN** an item is a preset
- **THEN** it is rendered with a badge that distinguishes it from single-action items

### Requirement: Edge-triggered auto-repeat for all launcher navigation

While the launcher is active, holding the controlling contact at a trackpad edge SHALL **auto-repeat** the corresponding navigation step, on **both axes**: the vertical edges repeat vertical stepping (switching bands when the band list is focused, or moving between grid rows / the Clipboard list when the grid is focused), and the horizontal edges repeat horizontal stepping (moving the item cursor within the grid, or crossing between the band list and the grid). Auto-repeat SHALL **accelerate** the longer an edge is held. It SHALL apply to every band's navigation, not only overflowing lists — a step that has nowhere to go SHALL simply clamp. In the **Clipboard band**, horizontal auto-repeat SHALL be suppressed (there horizontal is the deliberate pin / return-to-band-list action), while vertical auto-repeat still applies. A clamped step (one that does not move the selection) SHALL NOT reset the dwell, so holding at an edge with nothing further to reach still lets the current item arm and fire. Detection SHALL use hysteresis (enter < exit) so jitter at the boundary does not flap. The edge zone, base rate, acceleration, and maximum rate SHALL be tunable.

#### Scenario: Holding at a vertical edge keeps switching bands or stepping rows
- **WHEN** the user scrubs to the end of finger travel at the bottom (or top) trackpad edge
- **THEN** the active band keeps switching (band list focused) or the row selection keeps advancing (grid focused) without lifting, accelerating the longer the edge is held

#### Scenario: Holding at a horizontal edge keeps stepping items
- **WHEN** the grid is focused and the contact is held at the right/left edge
- **THEN** the item cursor keeps moving in that direction, accelerating, until it clamps (or crosses to the band list at the left edge)

#### Scenario: Clipboard band suppresses horizontal auto-repeat
- **WHEN** the Clipboard band is active and the contact is held at a horizontal edge
- **THEN** no pin / return-to-band-list action auto-repeats (only vertical auto-repeat applies there)

#### Scenario: A clamped edge does not block arming
- **WHEN** the selection is already at the end in the held direction and the contact stays at that edge
- **THEN** the auto-repeat is a no-op that does not reset the dwell, so the current item can still arm and fire

#### Scenario: Leaving the edge stops auto-repeat
- **WHEN** the contact moves back off the edge or lifts
- **THEN** auto-repeat stops

### Requirement: Pin and previous-band via horizontal travel in the Clipboard band

In the Clipboard band, with the key list focused and an entry selected, horizontal travel SHALL be interpreted as: **RIGHT toggles the pin** state of the selected entry, and **LEFT returns focus to the band list** (with the Clipboard band active, from which vertical travel reaches the previous band). Pinning via RIGHT SHALL give immediate feedback (a pin indicator, best-effort haptic) and SHALL NOT move the selection within the current session (consistent with the deferred-reorder pin model).

A horizontal pin action SHALL require a **deliberate excursion** whose travel exceeds a configurable threshold (clearly larger than the fine item-step distance), and SHALL fire **at most once per excursion** — the action is latched until the horizontal travel returns toward centre — so a small movement cannot pin/unpin repeatedly and holding an offset does not rapid-toggle. Vertical scrubbing SHALL clear any partial horizontal travel so it never pins by accident. The excursion distance SHALL be tunable.

#### Scenario: A small horizontal movement does not pin
- **WHEN** an entry is selected and the fingers move sideways less than the pin-excursion threshold
- **THEN** nothing is pinned and the focus does not change

#### Scenario: A deliberate right flick pins exactly once
- **WHEN** an entry is selected and the fingers make a deliberate rightward excursion past the threshold (and keep moving)
- **THEN** the entry's pin state toggles exactly once, a pin indicator shows, and the selection stays on that entry

#### Scenario: Returning to centre re-arms the action
- **WHEN** after a pin flick the fingers return toward centre and then make another deliberate right excursion
- **THEN** the pin toggles a second time (back to its original state)

#### Scenario: Left returns to the band list
- **WHEN** an entry is selected and the fingers move left toward the band list
- **THEN** focus crosses to the band list with the Clipboard band active (vertical travel from there reaches the previous band)

#### Scenario: Vertical scrubbing does not pin
- **WHEN** the user scrubs vertically through the key list with minor horizontal jitter
- **THEN** no entry is pinned (the partial horizontal travel is cleared by the vertical step)
