# permissions-onboarding Specification

## Purpose

Define detection of and guidance for granting the Accessibility, Screen Recording, and (if needed) Input Monitoring permissions, including deep-links to System Settings and graceful degradation when permissions are missing.
## Requirements
### Requirement: Detect required permissions
The system SHALL detect whether Accessibility and Screen Recording permissions are granted, and SHALL detect Input Monitoring status if the multitouch read requires it.

#### Scenario: Missing Accessibility detected
- **WHEN** Accessibility permission is not granted
- **THEN** the app reports Accessibility as missing in onboarding

#### Scenario: Missing Screen Recording detected
- **WHEN** Screen Recording permission is not granted
- **THEN** the app reports Screen Recording as missing in onboarding

### Requirement: Guide the user to grant permissions
The system SHALL present permission guidance on the Hub's **Setup** page (not a separate Setup/Onboarding window) that explains each required permission and deep-links to the relevant System Settings pane, and reflects live permission status.

#### Scenario: Deep-link to settings
- **WHEN** the user chooses to grant a missing permission from the Hub's Setup page
- **THEN** the app opens the corresponding System Settings privacy pane

#### Scenario: Setup reflects live status
- **WHEN** a permission is granted while the Hub's Setup page is open
- **THEN** the Setup page updates to reflect the granted state

### Requirement: Degrade gracefully when permissions are missing
The system SHALL behave safely when permissions are missing: without Accessibility it SHALL not attempt to raise windows; without Screen Recording it SHALL fall back to icon/title-only cards.

#### Scenario: No Accessibility disables raising
- **WHEN** Accessibility is not granted
- **THEN** the switcher does not attempt to raise windows and prompts the user to grant access

#### Scenario: No Screen Recording falls back to icons
- **WHEN** Screen Recording is not granted
- **THEN** the overlay shows app icon + title cards without thumbnails

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

### Requirement: Reminders permission for reminder tasks
The system SHALL detect Reminders (EventKit) authorization and SHALL request it **only when an add-to-reminders task first needs it**, never at launch and never on enabling the AI commands opt-in. If the permission is denied or restricted, the reminder task SHALL fail gracefully — surfacing that Reminders access is required and offering a deep-link to the relevant System Settings pane — and SHALL NOT block other AI commands.

#### Scenario: Reminders permission requested lazily
- **WHEN** the user runs an "add to reminders" task for the first time
- **THEN** the Reminders permission is requested at that moment, not at launch or at opt-in

#### Scenario: Denied reminders permission degrades gracefully
- **WHEN** Reminders permission is denied and a reminder task is confirmed
- **THEN** no reminder is created, the user is told access is required with a link to System Settings, and other AI commands continue to work

### Requirement: Contacts permission for contact tasks
The system SHALL detect Contacts authorization and SHALL request it **only when a new-contact task first needs it**, never at launch and never on enabling the AI commands opt-in. If the permission is denied or restricted, the contact task SHALL fail gracefully — surfacing that Contacts access is required and offering a deep-link to the relevant System Settings pane — and SHALL NOT block other AI commands.

#### Scenario: Contacts permission requested lazily
- **WHEN** the user runs a "new contact" task for the first time
- **THEN** the Contacts permission is requested at that moment, not at launch or at opt-in

#### Scenario: Denied contacts permission degrades gracefully
- **WHEN** Contacts permission is denied and a contact task is confirmed
- **THEN** no contact is created, the user is told access is required with a link to System Settings, and other AI commands continue to work

