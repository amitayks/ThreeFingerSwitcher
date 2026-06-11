## ADDED Requirements

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
