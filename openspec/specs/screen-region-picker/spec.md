# screen-region-picker Specification

## Purpose
TBD - created by archiving change add-region-capture-picker. Update Purpose after archive.
## Requirements
### Requirement: Interactive region picker surface
The system SHALL present an interactive **region-picker overlay** over the revealed desktop when a screen-region vision command is fired. The picker SHALL be cursor-driven (mouse-interactive), SHALL dim the screen and draw a live selection rectangle that follows the drag, SHALL preserve the captured front app's key/focus status (it is non-activating and SHALL never become key/main — no keyboard), and SHALL be torn down **synchronously** (ordered out and closed, never deferred behind an animation) to avoid the Space-switch ghost. It SHALL reuse the already-held Screen Recording permission and SHALL request no new permission.

#### Scenario: Picker presents over the revealed desktop
- **WHEN** a screen-region command is fired and the launcher has been dismissed
- **THEN** a mouse-interactive picker overlay appears over the revealed desktop with a crosshair / live-rectangle selection affordance

#### Scenario: Front app stays frontmost under the picker
- **WHEN** the picker is shown
- **THEN** the captured front app remains key/frontmost (the picker never activates or becomes key/main)

#### Scenario: Picker tears down synchronously
- **WHEN** the picker is dismissed (by capture or by cancel)
- **THEN** it is ordered out synchronously and does not linger on a subsequent Space switch

### Requirement: Drag selects a region; click-without-drag cancels
The picker SHALL capture the dragged rectangle as the designated region: on mouse-down it SHALL anchor the origin, on drag it SHALL track a live rectangle, and on mouse-up it SHALL commit that rectangle. A mouse-up whose rectangle is **below a small area / movement threshold** (a click without a meaningful drag) SHALL be treated as a **cancel** — defusing the picker, restoring the front app, opening no canvas, and generating nothing. There SHALL be **no keyboard cancel path** (the no-keypress rule); click-without-drag SHALL be the sole cancel gesture. The drag-versus-cancel decision SHALL be a pure, unit-testable verdict independent of AppKit.

#### Scenario: Drag commits a region
- **WHEN** the user presses, drags out a rectangle, and releases
- **THEN** that rectangle is the designated region to capture

#### Scenario: Click without dragging cancels
- **WHEN** the user clicks without dragging (a sub-threshold rectangle) and releases
- **THEN** the picker cancels, the front app is restored, and nothing is captured or generated

#### Scenario: No keyboard cancel path
- **WHEN** the picker is active
- **THEN** cancellation is performed by click-without-drag and no key press is required or consumed

### Requirement: Capture the designated region as a vision image
On commit, the system SHALL capture **only the designated rectangle** of the screen as a PNG image (via the held Screen Recording permission), excluding the app's own overlay windows and the cursor, and SHALL supply that PNG to the runtime as the command's image input. A cancelled pick SHALL yield **no image** (not a blank capture and not a full-screen fallback). When Screen Recording permission is missing at capture time, the system SHALL surface a **bounded, non-blocking** failure (clean headline, opt-in copyable details, retry) — never an app-modal `NSAlert`, never raw error text in a headline.

#### Scenario: Designated region is captured as PNG
- **WHEN** a region is committed
- **THEN** exactly that rectangle is captured as PNG and passed to the runtime as the command's image input

#### Scenario: The picker overlay is excluded from the capture
- **WHEN** the region is captured
- **THEN** the picker's own overlay windows are excluded so they do not appear in the captured image

#### Scenario: Missing permission is surfaced, not crashed
- **WHEN** Screen Recording permission is absent at capture time
- **THEN** a bounded, non-blocking failure is shown (not an `NSAlert`, not raw error text) and no image is produced

