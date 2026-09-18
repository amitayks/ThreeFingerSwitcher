## ADDED Requirements

### Requirement: Bounded host-reading cost
Reading the active host SHALL NOT be allowed to cost the main thread a full search on every poll tick when the previous search found nothing: after a failed Accessibility address-bar search for a given browser window, the system SHALL back off re-searching that window with an increasing interval (bounded), resetting on application activation, on a change of the browser's focused window, and on the next successful read. The Apple Events reader SHALL bound each request with a short timeout so an unresponsive browser cannot stall the app for the scripting default.

#### Scenario: Full-screen video does not tax the main thread
- **WHEN** the frontmost browser window has no findable address bar (full-screen video, presentation mode)
- **THEN** the address-bar search is not repeated on every poll tick; it is retried on a backed-off schedule and immediately after the browser's focused window changes

#### Scenario: A stalled browser cannot hang the app
- **WHEN** browser control is enabled and the browser stops servicing Apple Events
- **THEN** the read fails within a short bounded time and the system falls back to the app-level context
