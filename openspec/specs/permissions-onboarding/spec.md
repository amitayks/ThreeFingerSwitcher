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
The system SHALL present first-run permission guidance in the First Touch wizard and ongoing permission guidance on the Hub's **Setup** page. Both surfaces SHALL explain each required permission and what it unlocks, deep-link to the relevant System Settings pane, and reflect permission status live while visible — updating within about a second of a grant without requiring a manual refresh. The Screen Recording guidance SHALL state that the grant takes effect only after the app relaunches and SHALL offer an in-app relaunch action that performs the quit-and-reopen.

#### Scenario: Deep-link to settings
- **WHEN** the user chooses to grant a missing permission from the wizard or the Hub's Setup page
- **THEN** the app opens the corresponding System Settings privacy pane

#### Scenario: Status reflects live while visible
- **WHEN** a permission is granted in System Settings while the wizard's permission act or the Hub's Setup page is open
- **THEN** the surface updates to the granted state within about a second, without a manual refresh action

#### Scenario: Screen Recording relaunch is handled in-app
- **WHEN** the user grants Screen Recording and invokes the relaunch action
- **THEN** the app quits and reopens itself, and thumbnails work in the new process

### Requirement: First contact is owned by onboarding
While first-run onboarding is incomplete, a committed switch with Accessibility missing SHALL NOT trigger the OS Accessibility prompt mid-gesture — the commit is simply inert. The wizard SHALL be the only surface that initiates the Accessibility request during first run. After onboarding completes, the mid-gesture prompt path MAY serve as a safety net for the granted-then-revoked case.

#### Scenario: No mid-gesture prompt during first run
- **WHEN** onboarding is incomplete, Accessibility is missing, and the user commits a switch
- **THEN** no OS permission prompt appears mid-gesture and the commit is a no-op

#### Scenario: Safety net after onboarding
- **WHEN** onboarding is complete and Accessibility has been revoked since
- **THEN** a committed switch may surface the Accessibility request as before

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

