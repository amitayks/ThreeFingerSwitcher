## ADDED Requirements

### Requirement: Space-row display
The overlay SHALL group windows by Space (in Space order, omitting Spaces with no switchable windows) and display one Space-row at a time, starting on the current Space's row. It SHALL show a row indicator conveying which Space-row is shown and how many exist.

#### Scenario: Starts on the current Space's row
- **WHEN** the overlay is shown
- **THEN** the current Space's windows are displayed as the active row

#### Scenario: Empty Spaces are omitted
- **WHEN** a Space has no switchable windows
- **THEN** it is not shown as a row

#### Scenario: Row indicator reflects position
- **WHEN** there is more than one Space-row
- **THEN** the overlay shows an indicator of the current row position and the total number of rows

### Requirement: Animated row switching keeps the strip behavior
When the selected Space-row changes, the overlay SHALL swap to the new row's cards with a vertical animation, reset the highlighted card to the start of the new row, and preserve the existing adaptive width, thumbnails, and moving highlight within the row.

#### Scenario: Row swap shows the new Space's windows
- **WHEN** the selection moves to an adjacent Space-row
- **THEN** the strip updates to that Space's windows and the highlight starts at the first card

#### Scenario: Within-row behavior unchanged
- **WHEN** a row is shown
- **THEN** horizontal scrubbing, adaptive width, thumbnails, and the moving highlight behave as before within that row
