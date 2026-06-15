# dock-hover-detection Specification

## Purpose
TBD - created by archiving change dock-window-previews. Update Purpose after archive.
## Requirements
### Requirement: Opt-in Dock-hover detection, default off
The system SHALL provide Dock-hover window previews as an opt-in capability (`showDockPreviews`) that is **off by default**. When off, the cursor monitor and Dock reader SHALL NOT be installed and the native Dock SHALL be entirely unaffected. Enabling it SHALL take effect immediately — no re-login, no gesture relocation, and **no new permission** (it reuses the already-granted Accessibility and Screen Recording grants). Disabling it SHALL tear the subsystem back down.

#### Scenario: Feature off leaves the Dock untouched
- **WHEN** `showDockPreviews` is off
- **THEN** hovering a Dock tile produces no popup and no cursor tracking runs

#### Scenario: Enabling takes effect immediately
- **WHEN** the user turns `showDockPreviews` on
- **THEN** the next hover over a running app's Dock tile is detected with no re-login and no new permission prompt

#### Scenario: Disabling tears down
- **WHEN** the user turns `showDockPreviews` off while it was active
- **THEN** the cursor monitor and Dock reader stop and no further hover popups appear

### Requirement: Map Dock tiles to apps via the Accessibility tree
The system SHALL read the Dock's Accessibility tree to enumerate app tiles, resolving each running-app tile to its owning process and on-screen frame. Folder/stack, Trash, Downloads, separator, and minimized-window tiles SHALL NOT be treated as app tiles. If the Dock's Accessibility tree or a tile's attributes cannot be read, the system SHALL degrade to producing no popup (never crash, never raw error).

#### Scenario: Running-app tile resolves to a process
- **WHEN** the Dock tile list is read and a tile is a running application
- **THEN** that tile resolves to its owning process identifier and its current screen frame

#### Scenario: Non-app tiles are ignored
- **WHEN** the Dock contains folders/stacks, Trash, or the minimized-window region
- **THEN** those tiles are not treated as app tiles and never produce a window-preview popup

#### Scenario: Unreadable Dock degrades safely
- **WHEN** the Dock's Accessibility tree or a tile attribute cannot be read
- **THEN** no popup is shown and no error is surfaced

### Requirement: Detect hover by tracking the cursor against tile frames
The system SHALL detect a tile hover by tracking the cursor position and hit-testing it against the Dock tile frames, since the Dock emits no hover event. Cursor tracking SHALL be **edge-gated**: cheap/idle while the cursor is away from the Dock strip, and re-reading tile frames at interactive rate while the cursor is within the Dock strip (so magnified tiles are hit-tested against their current frames). The system SHALL emit an enter signal carrying the hovered app's process and an anchor rect, and a leave signal when the cursor exits the live zone.

#### Scenario: Hover over an app tile emits an anchored signal
- **WHEN** the cursor moves over a running app's Dock tile
- **THEN** the system emits a hover-enter for that app with an anchor rect at the tile's current frame

#### Scenario: Magnified tile is tracked to its current frame
- **WHEN** Dock magnification grows the hovered tile
- **THEN** the hit-test and anchor use the tile's current (magnified) frame, not a stale frame

#### Scenario: Tracking is idle away from the Dock
- **WHEN** the cursor is not within the Dock strip
- **THEN** no per-frame tile re-reads occur

### Requirement: Dock orientation, display, and auto-hide awareness
The system SHALL anchor the popup using the Dock's orientation (bottom, left, or right) and the display the Dock is on, placing the popup adjacent to the tile away from the screen edge. When the Dock is auto-hidden, the system SHALL treat it as idle until the Dock is revealed and tiles become hit-testable, then read the revealed tile frames rather than cached ones.

#### Scenario: Bottom Dock anchors above the tile
- **WHEN** the Dock is at the bottom and a tile is hovered
- **THEN** the popup anchors above the tile on the Dock's display

#### Scenario: Side Dock anchors beside the tile
- **WHEN** the Dock is on the left or right and a tile is hovered
- **THEN** the popup anchors beside the tile, away from the screen edge, on the Dock's display

#### Scenario: Auto-hidden Dock is idle until revealed
- **WHEN** the Dock is auto-hidden
- **THEN** no popup appears until the Dock reveals, after which tile frames are re-read from the revealed Dock

### Requirement: Hover lifecycle with a unified live zone and grace dismiss
The system SHALL treat the hovered tile and the open popup as one live zone so the cursor can travel from tile to popup without dismissing it. Moving the cursor to a different app tile SHALL swap the target app. Leaving the entire live zone SHALL dismiss the popup after a short grace period and end any in-flight live-preview session.

#### Scenario: Cursor travels from tile into popup
- **WHEN** the popup is open and the cursor moves off the tile and onto the popup
- **THEN** the popup stays open

#### Scenario: Moving to another tile swaps apps
- **WHEN** the popup is open and the cursor moves onto a different app's tile
- **THEN** the popup updates to that app's current-Space windows

#### Scenario: Leaving the live zone dismisses
- **WHEN** the cursor leaves both the tile and the popup for longer than the grace period
- **THEN** the popup dismisses and the live-preview capture session ends

