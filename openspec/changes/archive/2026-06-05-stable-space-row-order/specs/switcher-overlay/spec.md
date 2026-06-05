## MODIFIED Requirements

### Requirement: Space-row display
The overlay SHALL group windows by Space and display one Space-row at a time. Rows SHALL be ordered by the true Mission Control (display) order of Spaces, omitting Spaces with no switchable windows. This ordering SHALL be stable across reopens: a given Space occupies the same relative row position regardless of which Space is currently active. The overlay SHALL open with the current Space's row highlighted at its own position in that order (not moved to the first row). It SHALL show a row indicator conveying which Space-row is shown and how many exist.

#### Scenario: Rows follow Mission Control order
- **WHEN** the overlay is shown with switchable windows on multiple Spaces
- **THEN** the Space-rows are ordered by the Spaces' Mission Control order, not by which Space is current

#### Scenario: Ordering is stable across reopens
- **WHEN** the overlay is shown, then the active Space changes, then the overlay is shown again
- **THEN** each Space keeps the same relative row position across both showings

#### Scenario: Starts on the current Space's row at its own position
- **WHEN** the overlay is shown
- **THEN** the current Space's windows are the active (highlighted) row
- **AND** that row remains at the Space's own position in the Mission Control order rather than being moved to the first row

#### Scenario: Empty Spaces are omitted
- **WHEN** a Space has no switchable windows
- **THEN** it is not shown as a row

#### Scenario: Row indicator reflects position
- **WHEN** there is more than one Space-row
- **THEN** the overlay shows an indicator of the current row position and the total number of rows
