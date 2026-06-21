## ADDED Requirements

### Requirement: Screen-region commands acquire via the region picker before the canvas
When a `screenRegion` command is fired, the system SHALL acquire its image through the interactive region picker **before** opening the preview canvas: the launcher is dismissed to reveal the desktop, the user designates a region, and only the captured image is then supplied to the command. The executor SHALL accept this **pre-supplied** image and SHALL NOT perform its own additional screen capture for that command. If the pick is **cancelled** (a click without a drag), the command SHALL **abort** — no preview canvas opens and the model is not invoked. A cancelled pick is distinct from the "no input" state: it is a deliberate user abort, not a missing-input failure, and SHALL NOT surface a "no input" error.

#### Scenario: The picker runs before the canvas opens
- **WHEN** a `screenRegion` command is fired
- **THEN** the launcher is dismissed and the region picker runs first; the preview canvas opens only after a region is captured

#### Scenario: Executor uses the pre-supplied image
- **WHEN** a region is captured for a `screenRegion` command
- **THEN** the executor fires the request with that captured image and does not perform an additional screen capture

#### Scenario: Cancelled pick aborts the command
- **WHEN** the region pick is cancelled (a click without a drag)
- **THEN** no preview canvas opens and the model is not invoked, and no "no input" failure is shown
