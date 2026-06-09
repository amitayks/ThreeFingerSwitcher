## ADDED Requirements

### Requirement: Calendar permission for calendar tasks
The system SHALL detect Calendar (EventKit) authorization and SHALL request it **only when a calendar task first needs it**, never at launch and never on enabling the AI commands opt-in. If the permission is denied or restricted, the calendar task SHALL fail gracefully — surfacing that Calendar access is required and offering a deep-link to the relevant System Settings pane — and SHALL NOT block other AI commands.

#### Scenario: Calendar permission requested lazily
- **WHEN** the user runs an "add to calendar" task for the first time
- **THEN** the Calendar permission is requested at that moment, not at launch or at opt-in

#### Scenario: Denied calendar permission degrades gracefully
- **WHEN** Calendar permission is denied and a calendar task is confirmed
- **THEN** no event is created, the user is told access is required with a link to System Settings, and other AI commands continue to work

### Requirement: AI command input reuses held permissions and degrades
AI command input SHALL reuse the already-granted Accessibility permission (to read/replace selected text) and Screen Recording permission (to capture a screen region for vision), requesting no new permission for these paths. When Accessibility is unavailable, selection read/replace SHALL fall back as specified by selection I/O; when Screen Recording is unavailable, screen-region (vision) commands SHALL be reported as unavailable rather than failing silently.

#### Scenario: No new prompt for selection or vision input
- **WHEN** a selection or screen-region command runs with Accessibility and Screen Recording already granted
- **THEN** no additional permission prompt appears

#### Scenario: Missing Screen Recording disables vision commands clearly
- **WHEN** Screen Recording is not granted and a screen-region command is fired
- **THEN** the command reports that screen capture is unavailable rather than running on no image
