## ADDED Requirements

### Requirement: Enumerate normal windows across all Spaces
The system SHALL enumerate normal application windows across all Spaces, excluding minimized windows by default, and SHALL snapshot this ordered list at the start of each gesture.

#### Scenario: Includes windows on other Spaces
- **WHEN** the window list is built
- **THEN** normal windows on Spaces other than the current one are included

#### Scenario: Excludes minimized windows
- **WHEN** a window is minimized
- **THEN** it is not included in the switcher list

#### Scenario: Snapshot is frozen during gesture
- **WHEN** a gesture begins
- **THEN** the ordered window list is captured once and not re-ordered while scrubbing

### Requirement: MRU ordering with z-order fallback
The system SHALL order the window list most-recently-used so a short flick lands on the previously focused window, falling back to on-screen z-order when usage history is incomplete.

#### Scenario: Previous window is adjacent
- **WHEN** the user has two windows and switches between them
- **THEN** the most-recently-used window is positioned so a single step reaches the previous one

#### Scenario: Fallback to z-order
- **WHEN** focus history is unavailable for some windows
- **THEN** those windows are ordered by on-screen stacking order

### Requirement: Thumbnail capture via ScreenCaptureKit
The system SHALL capture per-window thumbnails using ScreenCaptureKit and SHALL degrade to an app-icon placeholder when a thumbnail is unavailable or Screen Recording permission is not granted.

#### Scenario: Thumbnail rendered when permitted
- **WHEN** Screen Recording permission is granted and a window is on the list
- **THEN** a thumbnail image is captured and provided to the overlay

#### Scenario: Placeholder when capture unavailable
- **WHEN** a thumbnail cannot be captured for a window
- **THEN** the app icon is used as a placeholder

### Requirement: Raise and focus the chosen window
The system SHALL raise and focus a chosen window using the Accessibility API and application activation, bringing it forward and giving it keyboard focus.

#### Scenario: Commit raises and focuses
- **WHEN** a window is committed
- **THEN** it is raised (kAXRaiseAction), set as main/focused, and its application is activated so it has keyboard focus

#### Scenario: Cross-Space commit switches once
- **WHEN** the committed window is on another Space
- **THEN** the Space switch occurs exactly once at commit time, not during scrubbing
