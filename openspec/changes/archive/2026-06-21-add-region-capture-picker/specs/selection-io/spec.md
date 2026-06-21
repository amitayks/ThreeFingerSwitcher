## MODIFIED Requirements

### Requirement: Screen-region capture for vision input
The system SHALL capture a **user-designated region** of the screen as an image for vision commands, using the interactive region picker, reusing the Screen Recording permission the app already holds. The captured image SHALL be the **designated rectangle only** (not the full display) and SHALL be supplied to the runtime as the command's input. A **cancelled** pick (a click without a drag) SHALL yield **no image**, so the command aborts rather than running on a blank or full-screen capture. The capture SHALL exclude the app's own overlay windows.

#### Scenario: Designated region capture feeds the vision model
- **WHEN** a screen-region command is fired and the user drags out a region
- **THEN** that region (only) is captured as an image and passed to the runtime as input

#### Scenario: Cancelled pick yields no image
- **WHEN** the user cancels the region pick (a click without a drag)
- **THEN** no image is produced and the command does not run on a fallback capture

#### Scenario: Region capture reuses the held permission
- **WHEN** a region is captured
- **THEN** the already-held Screen Recording permission is used and no new permission is requested
