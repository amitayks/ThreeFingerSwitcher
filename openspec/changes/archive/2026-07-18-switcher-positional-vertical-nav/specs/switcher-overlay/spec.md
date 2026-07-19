# Delta: switcher-overlay (switcher-positional-vertical-nav)

## MODIFIED Requirements

### Requirement: Grid navigation within a Space

Within a Space, horizontal scrubbing SHALL move the selection among the cards of the current visual row, and vertical scrubbing SHALL move the selection between visual rows. Horizontal movement SHALL stay within the current visual row (it SHALL NOT jump to another row). Moving to an adjacent visual row SHALL land the selection **positionally**: on the card of that row whose horizontal span is nearest the selection's preferred x-position (the anchor), NOT unconditionally on the row's first card. The anchor SHALL be the x-center of the card selected when a run of vertical steps begins, expressed relative to the grid's horizontal center; it SHALL be reused unchanged by every subsequent vertical step in the run (so travelling several rows holds a straight vertical line rather than drifting through narrow cards), and SHALL be cleared by any horizontal step, any linear (reel-order) selection change, and a fresh presentation of the overlay. The landing card SHALL be the one minimizing the horizontal distance from the anchor to the card's span (zero when the anchor falls within the span), with ties broken toward the nearer card center.

#### Scenario: Horizontal moves within the current row

- **WHEN** the selection is in a visual row and the user scrubs horizontally
- **THEN** the selection moves among the cards of that same visual row and does not jump to another row

#### Scenario: Vertical moves between visual rows lands positionally

- **WHEN** the user scrubs vertically and an adjacent visual row exists within the Space
- **THEN** the selection moves to that row, landing on the card whose horizontal span is nearest the selection's anchor x-position — the card directly above/below when one overlaps the anchor

#### Scenario: A run of vertical steps holds a straight line

- **WHEN** the user steps vertically through several rows in succession (no horizontal step in between)
- **THEN** every landing uses the anchor captured at the first vertical step (the x-center of the card the run started on), so an intermediate narrow card does not bend the path

#### Scenario: A horizontal step re-anchors

- **WHEN** the user steps horizontally after vertical travel and then steps vertically again
- **THEN** the new vertical landing is computed from the newly selected card's x-center (the previous anchor is discarded)

#### Scenario: Selection kept visible when the grid overflows

- **WHEN** the selected card would fall outside the visible canvas because the grid is taller than the canvas
- **THEN** the canvas scrolls so the selected card remains visible

### Requirement: Animated row switching keeps the strip behavior
When the shown Space changes, the overlay SHALL swap to the new Space's window grid with a vertical animation and preserve the solved uniform-scale layout, thumbnails, and moving highlight within the new grid. Where the highlight lands SHALL depend on how the Space was entered: a **vertical scrub (or arrow) crossing the grid edge** SHALL land positionally — entering upward (to the next Space) lands in the new grid's **bottom** visual row and entering downward (to the previous Space) lands in the new grid's **top** visual row, in both cases on the card nearest the selection's anchor x-position (spatially continuous with the reel's vertical stacking); a **linear (reel-order) flow** into a Space keeps its own defined landing (next Space's first window forward, previous Space's last window backward); any other entry (including a fresh presentation) SHALL land on the first card (bottom-left). During the animation all cards SHALL translate together as a single group; a window thumbnail that becomes available WHILE the animation is in progress SHALL NOT alter a card mid-animation (which would interrupt the motion), but SHALL be applied once the animation settles. Within a single Space, horizontal and vertical scrubbing SHALL navigate the grid (per the grid-navigation requirement) rather than swapping Spaces.

#### Scenario: Space swap shows the new Space's grid

- **WHEN** the selection moves to an adjacent Space
- **THEN** the grid updates to that Space's windows with a vertical animation and the highlight lands per the entry mode (positional for a vertical edge crossing, reel-defined for a linear flow, first card otherwise)

#### Scenario: Vertical edge crossing lands positionally in the adjacent Space

- **WHEN** the selection is on the current grid's top visual row and the user scrubs up (or the bottom visual row and scrubs down)
- **THEN** the overlay switches to the adjacent Space and the highlight lands in that grid's bottom (respectively top) visual row on the card nearest the anchor x-position, not on a hardcoded first card

#### Scenario: All cards move together; late thumbnails fill in after

- **WHEN** a Space switch is animating and a window's thumbnail finishes capturing partway through the animation
- **THEN** every card translates together for the whole animation (no card snaps to place or changes content mid-motion)
- **AND** the newly captured thumbnail appears on its card once the animation has settled
- **AND** a thumbnail already cached before the switch is shown from the start and animates with its card

#### Scenario: Within-Space behavior is grid navigation

- **WHEN** a Space's grid is shown
- **THEN** horizontal and vertical scrubbing navigate cards within that grid, and the solved scale, thumbnails, and moving highlight behave consistently within it
