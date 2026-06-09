## ADDED Requirements

### Requirement: Tasks use schema-targeted structured output (validated, repairable, declinable)
Each background task kind SHALL be defined by a JSON Schema describing the action's parameters. The model SHALL produce output targeting that schema; the system SHALL **validate** it and **repair or retry** on mismatch within a bounded loop before treating it as an action, and SHALL allow the model to **decline** ("not applicable") rather than fabricate values when the input does not fit the task. The system SHALL NOT depend on hard token-level caging to obtain structure, and SHALL NOT dispatch an action that failed validation.

#### Scenario: Calendar task produces a well-formed event
- **WHEN** an "add to calendar" command runs on text describing a meeting
- **THEN** the model returns a schema-valid object with the event fields (e.g. title, start, end, attendees, notes)

#### Scenario: Non-conforming output is repaired, not dispatched raw
- **WHEN** the model output does not satisfy the task schema
- **THEN** the system repairs or retries it; if it still cannot produce a valid action, the dispatcher receives no action and the user is told it could not be produced

#### Scenario: Model declines when the input does not fit the task
- **WHEN** an "add to calendar" command runs on text that describes no meeting
- **THEN** the model may return a "not applicable" result and no event action is dispatched (it does not invent an event)

### Requirement: Action review before side effects (default on, user-overridable)
A side-effecting task SHALL present an **action-review preview** (the concrete fields that will be applied) before it executes **when the command's `confirmBeforeRun` is enabled**, and `confirmBeforeRun` SHALL **default to enabled** for side-effecting tasks. The user MAY disable it per command; when disabled, the task commits without the extra action-review step (the baseline deliberate commit still applies). Discarding SHALL always cancel the task with no side effect.

#### Scenario: Action is shown before it fires (default)
- **WHEN** a calendar/save/open/send task whose command has `confirmBeforeRun` enabled has produced its parsed action
- **THEN** the user sees the action's fields and nothing is applied until they commit

#### Scenario: Confirmation defaults on for side-effecting tasks
- **WHEN** a side-effecting command is created without an explicit choice
- **THEN** its `confirmBeforeRun` defaults to enabled

#### Scenario: User may disable review for a trusted task
- **WHEN** the user disables `confirmBeforeRun` on a side-effecting command and commits it
- **THEN** the task executes its side effect without the extra action-review step, honoring the stored value

#### Scenario: Discard cancels with no effect
- **WHEN** the user discards a task before committing
- **THEN** no event is created, no file is written, no tool is opened, and nothing is sent

### Requirement: Add-to-calendar task
The system SHALL provide an "add to calendar" task that creates a calendar event from the parsed `{title, start, end, attendees, notes}` via EventKit. Creating the event SHALL require the Calendar permission, requested only at first use (see permissions-onboarding), and SHALL occur only after the confirmation preview is confirmed.

#### Scenario: Confirmed event is created
- **WHEN** the user confirms a parsed calendar action and Calendar permission is granted
- **THEN** a matching event is created in the user's calendar

#### Scenario: Permission denied is handled
- **WHEN** Calendar permission is denied
- **THEN** the task does not create an event and the user is told the permission is required

### Requirement: Save-to-project task
The system SHALL provide a "save to project" task that appends the (optionally model-refined) content, with its source app/URL and a timestamp, to a per-project note on disk, reusing the on-disk store pattern used by clipboard history. The target project SHALL be part of the command/task configuration.

#### Scenario: Content is appended to the project note
- **WHEN** the user confirms a "save to project N" action
- **THEN** the content plus its source and timestamp are appended to project N's note on disk

### Requirement: Open-tool-with-payload task
The system SHALL provide an "open tool with this payload" task that generates a payload (e.g. a prompt) and opens a target tool with it — by writing a payload file and opening the tool via the existing launch mechanism, or by invoking a Shortcut — after confirmation.

#### Scenario: Tool opens with the generated payload
- **WHEN** the user confirms an "open tool with this idea" action
- **THEN** the target tool is opened with the generated payload available to it

### Requirement: Send-to-destination task
The system SHALL provide a "send to destination" task whose output target is a configured destination (e.g. a Shortcut, a URL scheme, or a shell-out adapter), fed the (optionally model-refined) content after confirmation. Send-to SHALL be modeled as a command output target, not a separate feature.

#### Scenario: Confirmed content is routed to the destination
- **WHEN** the user confirms a "send to <destination>" action
- **THEN** the content is delivered to that destination via its adapter

#### Scenario: Model may refine before sending
- **WHEN** a send-to command specifies refinement in its prompt
- **THEN** the content delivered to the destination is the model-refined version
