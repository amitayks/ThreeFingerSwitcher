# switcher-overlay Specification

## Purpose

Define the non-activating overlay panel that renders the horizontal thumbnail strip and the live moving highlight, never steals focus, and appears above all content on the active screen.
## Requirements
### Requirement: Non-activating overlay that never steals focus
The overlay SHALL be a borderless, non-activating panel that ignores mouse events and does not become key or main, so the previously focused window can be raised cleanly on commit.

#### Scenario: Overlay does not take focus
- **WHEN** the overlay appears
- **THEN** the previously focused application remains the focus target for commit
- **AND** the overlay window is never itself a raise candidate

#### Scenario: Overlay ignores the pointer
- **WHEN** the overlay is visible and the pointer moves over it
- **THEN** mouse events pass through and do not interact with the overlay

### Requirement: Thumbnail strip with cards
The overlay SHALL render a horizontal strip of cards, one per window in the snapshot, each showing the app icon, window title, and thumbnail (or placeholder).

#### Scenario: One card per window
- **WHEN** the overlay is shown for a snapshot of N windows
- **THEN** N cards are rendered in the snapshot order

#### Scenario: Card content
- **WHEN** a card is rendered
- **THEN** it shows the owning app icon, the window title, and a thumbnail image or icon placeholder

### Requirement: Moving highlight tracks selection
The overlay SHALL visually highlight the currently selected card and SHALL update the highlight in real time as the selection index changes during scrubbing.

#### Scenario: Highlight follows scrub
- **WHEN** the selection index changes during scrubbing
- **THEN** the highlight moves to the newly selected card without re-creating the strip

#### Scenario: Selected card kept visible
- **WHEN** the selected card would fall outside the visible area
- **THEN** the strip scrolls so the highlighted card remains visible

### Requirement: Overlay appears on the active screen above all content
The overlay SHALL appear on the active screen at a window level above normal windows and across all Spaces, and SHALL hide promptly on commit or cancel.

#### Scenario: Shown above other windows
- **WHEN** the overlay is activated
- **THEN** it renders above normal application windows on the active screen

#### Scenario: Hidden on end of gesture
- **WHEN** the gesture commits or cancels
- **THEN** the overlay hides promptly

### Requirement: Adaptive container width
The overlay container SHALL adapt its width to the number of cards: when the cards fit within the available screen width it SHALL shrink to wrap the cards and center horizontally on the active screen; when the cards exceed the available width it SHALL clamp to the maximum width, stay centered, and scroll to keep the highlighted card visible.

#### Scenario: Short list hugs and centers
- **WHEN** the overlay is shown for a snapshot whose cards fit within the available screen width
- **THEN** the container width equals the card content width (the rounded background wraps the cards with no empty trailing space)
- **AND** the container is centered horizontally on the active screen
- **AND** no scrolling occurs

#### Scenario: Overflowing list clamps and scrolls
- **WHEN** the overlay is shown for a snapshot whose cards are wider than the available screen width
- **THEN** the container width is clamped to the available screen width (minus side margins) and centered
- **AND** scrubbing scrolls the strip to keep the highlighted card visible

#### Scenario: Card metrics are a single source of truth
- **WHEN** the container width is computed
- **THEN** it uses the same card width, spacing, and padding values that the card strip uses to lay out, so the two cannot diverge

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

### Requirement: Animated row switching keeps the strip behavior
When the selected Space-row changes, the overlay SHALL swap to the new row's cards with a vertical animation, reset the highlighted card to the start of the new row, and preserve the existing adaptive width, thumbnails, and moving highlight within the row.

#### Scenario: Row swap shows the new Space's windows
- **WHEN** the selection moves to an adjacent Space-row
- **THEN** the strip updates to that Space's windows and the highlight starts at the first card

#### Scenario: Within-row behavior unchanged
- **WHEN** a row is shown
- **THEN** horizontal scrubbing, adaptive width, thumbnails, and the moving highlight behave as before within that row

### Requirement: Overlay panel does not perturb focus arbitration
The overlay panel SHALL use a window level and collection behavior that do not interfere with the WindowServer's focus/Space arbitration, and SHALL never be left ordered-in after a gesture ends.

#### Scenario: Non-interfering window configuration
- **WHEN** the overlay panel is created
- **THEN** it uses a transient window level (above normal windows and the menu bar, not the screen-saver band) and does not use an Exposé-exempt collection behavior

#### Scenario: Panel is always torn down
- **WHEN** a gesture ends by commit, cancel, the touch engine stopping, or the app resigning active
- **THEN** the overlay panel is ordered out (idempotently), never left visible

#### Scenario: Modal alerts are frontmost
- **WHEN** the app shows a modal alert
- **THEN** it activates first so the alert is key and frontmost rather than spinning a modal loop owned by a non-frontmost app

### Requirement: Switcher floats above an open Mission Control
When the switcher is triggered while Mission Control is open (opened by the app's gesture ownership), the overlay SHALL be presented above Mission Control so all cards are fully visible. This elevated presentation (raised window level, Exposé-exempt) SHALL be used **only** while Mission Control is open; when it is not, the overlay SHALL keep its normal arbitration-safe presentation so focus/Space behavior is unchanged.

#### Scenario: Overlay is visible over Mission Control
- **WHEN** Mission Control is open and the user triggers the switcher
- **THEN** the switcher cards render above the Mission Control windows, not behind them

#### Scenario: Normal presentation when Mission Control is closed
- **WHEN** the switcher is triggered without Mission Control open
- **THEN** the overlay uses its normal level/behavior and focus/Space handling is unchanged

### Requirement: Selecting while Mission Control is open dismisses it and focuses the window
When a window is committed in the switcher while Mission Control is open, the system SHALL dismiss Mission Control and then focus the selected window via the robust raise. Dismissal SHALL never itself open Mission Control if it was already closed.

#### Scenario: Commit closes Mission Control and focuses the window
- **WHEN** the user selects a window in the switcher while Mission Control is open
- **THEN** Mission Control closes and the selected window is raised and focused

#### Scenario: Stale state does not reopen Mission Control
- **WHEN** a commit's dismiss runs but Mission Control is no longer open
- **THEN** Mission Control is not opened, and the selected window is still raised and focused

