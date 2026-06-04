## ADDED Requirements

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
