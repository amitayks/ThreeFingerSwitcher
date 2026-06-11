## ADDED Requirements

### Requirement: Tool and shortcut task targets are chosen from a list
The command editor SHALL let the user choose an **open-tool** target (an installed app or a Shortcut) and a **send-to Shortcut** destination from an **enumerated list** — the installed applications and the user's Shortcuts — rather than requiring the user to type the exact identifier (which the user cannot reliably know). Selecting an app SHALL store a launchable reference the dispatcher can act on (the app's path), and selecting a Shortcut SHALL store its name, so the authored value is always well-formed without guesswork. A free-text **custom** entry SHALL remain available for targets not in the list (e.g. a not-yet-created Shortcut), and the URL-scheme / shell destinations (which are inherently free-form) SHALL keep their text entry.

#### Scenario: Open-tool target picked from installed apps and shortcuts
- **WHEN** the user configures an "open tool with payload" task
- **THEN** they pick an installed app or a Shortcut from a list, and the stored tool value is a launchable reference (an app path, or a Shortcut name) — no manual identifier typing is required

#### Scenario: Send-to Shortcut destination picked from a list
- **WHEN** the user configures a "send to Shortcut" destination
- **THEN** they pick from the list of the user's Shortcuts and the chosen name is stored

#### Scenario: Custom target remains available
- **WHEN** the desired target is not in the enumerated list (e.g. a Shortcut not yet created)
- **THEN** a custom free-text entry is still available so the command can still be authored

### Requirement: Add-to-reminders task
The system SHALL provide an "add to reminders" task that creates a reminder from a schema-targeted, validated, **declinable** parsed action (`{title, due?, notes?, priority?}`) via EventKit reminders. The model SHALL be able to decline ("not applicable") rather than fabricate a reminder when the input describes no task. Creating the reminder SHALL require the **Reminders** permission, requested only at first use (see permissions-onboarding), SHALL occur only after the action-review confirmation when `confirmBeforeRun` is enabled (the default for side-effecting tasks), and a denied permission SHALL surface a clean, recoverable failure naming Reminders (per ai-error-handling) rather than silently completing.

#### Scenario: Confirmed reminder is created
- **WHEN** the user confirms a parsed reminder action and Reminders permission is granted
- **THEN** a matching reminder is created in the user's Reminders

#### Scenario: Model declines when the input is not a task
- **WHEN** an "add to reminders" command runs on text that describes no task
- **THEN** the model returns a "not applicable" result and no reminder is created

#### Scenario: Reminders permission denied is handled
- **WHEN** Reminders permission is denied
- **THEN** no reminder is created and the user is told the Reminders permission is required, with a pointer to the relevant System Settings pane

### Requirement: New-contact task
The system SHALL provide a "new contact" task that creates a contact card from a schema-targeted, validated, **declinable** parsed action (`{name, email?, phone?, organization?, notes?}`) via the Contacts framework. The model SHALL be able to decline ("not applicable") when the input contains no contact details. Creating the contact SHALL require the **Contacts** permission, requested only at first use (see permissions-onboarding), SHALL occur only after the action-review confirmation when `confirmBeforeRun` is enabled (the default for side-effecting tasks), and a failure to save SHALL surface a clean, recoverable failure (per ai-error-handling) rather than reporting success.

#### Scenario: Confirmed contact is created
- **WHEN** the user confirms a parsed contact action and Contacts permission is granted
- **THEN** a matching contact card is created in the user's Contacts

#### Scenario: Model declines when there is no contact
- **WHEN** a "new contact" command runs on text containing no contact details
- **THEN** the model returns a "not applicable" result and no contact is created

#### Scenario: Contacts permission denied is handled
- **WHEN** Contacts permission is denied
- **THEN** no contact is created and the user is told the Contacts permission is required, with a pointer to the relevant System Settings pane
