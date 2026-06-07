## MODIFIED Requirements

### Requirement: Item stepping and context stepping

While the launcher overlay is active, horizontal travel SHALL step the selection between items within the current context band (one item per item-step distance, with carry), and vertical travel SHALL step the selection between context bands (one band per context-step distance, with carry). Stepping past the first/last item or band SHALL clamp (not wrap) unless wrap is configured.

The **Clipboard band** is an exception to the horizontal mapping above. Because it is a single-column master-detail list (key list + value preview), horizontal travel does NOT step items there; it is repurposed (RIGHT pins the selected entry, LEFT switches to the previous band — see the Clipboard band navigation requirement), while vertical travel scrubs between entries (rows) and, at the top edge, rises to the band headers exactly as elsewhere.

#### Scenario: Horizontal steps items
- **WHEN** the overlay is active on a normal band and the fingers move horizontally past the item-step distance
- **THEN** the selection moves to the adjacent item in the current band (and again per further item-step distance)

#### Scenario: Vertical steps context bands
- **WHEN** the overlay is active and the fingers move vertically past the context-step distance
- **THEN** the selection moves to the adjacent context band

#### Scenario: Selecting an empty edge clamps
- **WHEN** the selection is on the first item and the user steps backward
- **THEN** the selection stays on the first item (no wrap, by default)

#### Scenario: Clipboard band overrides horizontal stepping
- **WHEN** the overlay is active on the Clipboard band and the fingers move horizontally
- **THEN** the selection does not step to another entry; instead the pin / previous-band behavior applies

## ADDED Requirements

### Requirement: Clipboard band master-detail layout and content preview

The Clipboard band SHALL render as a master-detail layout rather than the icon grid: a multi-line list of truncated **keys** on the left (one entry per line, with a type glyph and a pin indicator when pinned) and a single large **value preview** on the right that shows the **actual content** of the currently selected entry — a rendered image for image entries, a content preview of the file (not merely its icon) for file entries, the full text for text entries, and a color swatch for color entries. The overlay SHALL be sized large enough to show several keys and a sizeable value preview at once. The value preview SHALL NOT be a separately focusable/navigable pane (there is no horizontal crossing into it); content that overflows the preview region MAY be clipped in this layout.

#### Scenario: Selecting an entry previews its real content
- **WHEN** the selection rests on an image, file, text, or color entry
- **THEN** the value preview shows that entry's actual rendered content (image, file content preview, full text, or color swatch), not just a type icon

#### Scenario: Keys list shows many entries with pin markers
- **WHEN** the Clipboard band is shown
- **THEN** the left column lists multiple truncated keys, one per line, and pinned entries display a pin indicator

### Requirement: Pin and previous-band via horizontal travel in the Clipboard band

In the Clipboard band, with an entry selected, horizontal travel SHALL be interpreted as: **RIGHT toggles the pin** state of the selected entry, and **LEFT switches to the previous band** (dropping the selection into that band's grid). Pinning via RIGHT SHALL give immediate feedback (a pin indicator, best-effort haptic) and SHALL NOT move the selection within the current session (consistent with the deferred-reorder pin model).

A horizontal action SHALL require a **deliberate excursion** whose travel exceeds a configurable threshold (clearly larger than the fine item-step distance), and SHALL fire **at most once per excursion** — the action is latched until the horizontal travel returns toward centre — so a small movement cannot pin/unpin repeatedly and holding an offset does not rapid-toggle. Vertical scrubbing SHALL clear any partial horizontal travel so it never pins by accident. The excursion distance SHALL be tunable.

#### Scenario: A small horizontal movement does not pin
- **WHEN** an entry is selected and the fingers move sideways less than the pin-excursion threshold
- **THEN** nothing is pinned and the band does not change

#### Scenario: A deliberate right flick pins exactly once
- **WHEN** an entry is selected and the fingers make a deliberate rightward excursion past the threshold (and keep moving)
- **THEN** the entry's pin state toggles exactly once, a pin indicator shows, and the selection stays on that entry

#### Scenario: Returning to centre re-arms the action
- **WHEN** after a pin flick the fingers return toward centre and then make another deliberate right excursion
- **THEN** the pin toggles a second time (back to its original state)

#### Scenario: Deliberate left flick leaves to the previous band
- **WHEN** an entry is selected and the fingers make a deliberate leftward excursion past the threshold
- **THEN** the overlay switches to the previous band with the selection in that band's grid

#### Scenario: Vertical scrubbing does not pin
- **WHEN** the user scrubs vertically through the key list with minor horizontal jitter
- **THEN** no entry is pinned (the partial horizontal travel is cleared by the vertical step)

### Requirement: Edge-triggered auto-repeat for all launcher navigation

While the launcher is active, holding the controlling contact at a trackpad edge SHALL **auto-repeat** the corresponding navigation step, on **both axes**: the horizontal edges repeat horizontal stepping (moving the item cursor within the grid, or switching bands when the cursor is on the headers row), and the vertical edges repeat vertical stepping (moving between grid rows / the Clipboard list). Auto-repeat SHALL **accelerate** the longer an edge is held. It SHALL apply to every band's navigation, not only overflowing lists — a step that has nowhere to go SHALL simply clamp. In the **Clipboard band**, horizontal auto-repeat SHALL be suppressed (there horizontal is the deliberate pin / previous-band action), while vertical auto-repeat still applies. A clamped step (one that does not move the selection) SHALL NOT reset the dwell, so holding at an edge with nothing further to reach still lets the current item arm and fire. Detection SHALL use hysteresis (enter < exit) so jitter at the boundary does not flap. The edge zone, base rate, acceleration, and maximum rate SHALL be tunable.

#### Scenario: Holding at a vertical edge keeps stepping rows
- **WHEN** the user scrubs to the end of finger travel at the bottom (or top) trackpad edge
- **THEN** the selection keeps advancing down (or up) without lifting, accelerating the longer the edge is held

#### Scenario: Holding at a horizontal edge keeps stepping items or switching bands
- **WHEN** the cursor is in a grid (or on the headers row) and the contact is held at the right/left edge
- **THEN** the item cursor keeps moving (or the band keeps switching) in that direction, accelerating, until it clamps

#### Scenario: Clipboard band suppresses horizontal auto-repeat
- **WHEN** the Clipboard band is active and the contact is held at a horizontal edge
- **THEN** no pin / previous-band action auto-repeats (only vertical auto-repeat applies there)

#### Scenario: A clamped edge does not block arming
- **WHEN** the selection is already at the end in the held direction and the contact stays at that edge
- **THEN** the auto-repeat is a no-op that does not reset the dwell, so the current item can still arm and fire

#### Scenario: Leaving the edge stops auto-repeat
- **WHEN** the contact moves back off the edge or lifts
- **THEN** auto-repeat stops
