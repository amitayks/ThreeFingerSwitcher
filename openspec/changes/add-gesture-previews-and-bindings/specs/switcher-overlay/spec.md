## MODIFIED Requirements

### Requirement: Moving highlight tracks selection
The overlay SHALL visually highlight the currently selected card and SHALL update the highlight in real time as the selection index changes during scrubbing, across both horizontal (within-row) and vertical (between-row) movement. The **direction** in which a given scrub moves the selection index — per axis (windows / Space-rows) — SHALL be the user's **configured switcher binding** (`gesture-bindings`), defaulting to **normal** on both axes (the prior reverse-direction behavior expressed as a binding). Reversing an axis SHALL only flip the sign of the index movement, never its magnitude or the step distance.

#### Scenario: Highlight follows scrub
- **WHEN** the selection index changes during scrubbing
- **THEN** the highlight moves to the newly selected card without re-creating the grid

#### Scenario: Selected card kept visible
- **WHEN** the selected card would fall outside the visible area, horizontally or vertically
- **THEN** the canvas scrolls so the highlighted card remains visible

#### Scenario: Reversed axis flips only the direction
- **WHEN** the user sets the windows (or Spaces) axis to reversed and scrubs that axis
- **THEN** the highlight moves in the opposite direction by the same per-step magnitude as the normal binding
