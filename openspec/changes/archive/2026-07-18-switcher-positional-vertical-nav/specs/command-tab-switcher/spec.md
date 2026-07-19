# Delta: command-tab-switcher (switcher-positional-vertical-nav)

## MODIFIED Requirements

### Requirement: Arrow keys navigate the open switcher

While the overlay is open and ⌘ is held, the arrow keys SHALL navigate it (Windows-Alt-Tab style): Left/Right SHALL step the selection backward/forward through windows exactly as Shift+Tab / Tab do (flowing across Spaces one window at a time), and Up/Down SHALL navigate the current Space's grid vertically exactly as the trackpad's vertical scrub does — stepping between the grid's visual rows with positional (nearest-anchor-x) landing, and switching to the adjacent Space ONLY when the step would cross the grid's top (up) or bottom (down) edge, landing positionally in that Space per the switcher-overlay grid-navigation requirements. Whether the Space sequence wraps or clamps at its ends SHALL follow the same wrap setting the trackpad path uses. Arrow direction SHALL be literal — Up always moves the highlight visually up — and SHALL NOT be flipped by the scrub-reversal setting (that setting expresses a finger-vs-content *scrub* preference, which has no meaning for a directional keypress). Arrow keys SHALL be consumed only while a session is open (so ⌘-arrow shortcuts are untouched when the switcher is closed) and SHALL NOT themselves open the switcher.

#### Scenario: Right/Left step through windows across Spaces

- **WHEN** the switcher is open and the user presses Right (or Left) with ⌘ held
- **THEN** the selection steps forward (or backward) one window along the same flat order Tab uses, flowing into the adjacent Space at a Space boundary

#### Scenario: Up/Down navigate the grid's visual rows

- **WHEN** the switcher is open, the current Space's grid has more than one visual row, the selection is not on the edge row in the pressed direction, and the user presses Up (or Down) with ⌘ held
- **THEN** the selection moves to the adjacent visual row within the same Space, landing positionally (nearest the anchor x-position), and no Space switch occurs

#### Scenario: Up/Down switch Space only at the grid edge

- **WHEN** the switcher is open and the user presses Up on the grid's top visual row (or Down on the bottom visual row) with ⌘ held
- **THEN** the overlay switches to the adjacent Space and the highlight lands positionally (bottom row of the new grid going up, top row going down), matching the trackpad's vertical edge crossing

#### Scenario: Arrows do not open the switcher and leave ⌘-arrow shortcuts alone

- **WHEN** ⌘ is held but the switcher is not open and the user presses an arrow
- **THEN** the arrow is not consumed (the normal ⌘-arrow shortcut reaches the focused app) and the switcher does not open
