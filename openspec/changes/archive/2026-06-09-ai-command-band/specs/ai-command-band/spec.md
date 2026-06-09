## ADDED Requirements

### Requirement: AI command value model and persistence
The system SHALL define an AI command as a Codable value type carrying: a stable identifier, a display name, an icon and tint, an **input source** (`selection` | `clipboard` | `screenRegion` | `none`), a **prompt template** string, an **output target** (`replaceSelection` | `pasteAtCursor` | `previewOnly` | `task(TaskKind)` | `sendTo(Destination)`), a **model selector** (v1: on-device Gemma 4), and a **confirmBeforeRun** flag. The list of commands SHALL persist across launches and apply immediately when changed, stored separately from the Favorites record (a command is configuration, not a Favorites item).

#### Scenario: Commands persist across launches
- **WHEN** the user creates AI commands and relaunches the app
- **THEN** the same commands, in the same order, are present

#### Scenario: Commands are not written into Favorites
- **WHEN** AI commands exist and the Favorites record is inspected
- **THEN** the Favorites record contains no AI command items (they live in their own store)

#### Scenario: confirmBeforeRun defaults on for side-effecting output but is honored
- **WHEN** a command with a side-effecting task or send-to destination is created without an explicit choice
- **THEN** its `confirmBeforeRun` defaults to true; if the user later sets it false, that stored value is honored at run time (not overridden)

### Requirement: Authoring AI commands in Settings
The system SHALL provide a keyboardless-use-time authoring UI, reachable from Settings, to create, edit, reorder, and delete AI commands. The editor SHALL let the user set every field of the command model — name, icon, tint, input source, prompt template, output target (and, for task/send-to targets, the task kind / destination), model, and confirm-before-run — and SHALL persist each edit immediately.

#### Scenario: Create a command
- **WHEN** the user adds a command, names it, writes a prompt template, and picks an input source and output target
- **THEN** the command is saved and appears in the AI command band on the next launcher open

#### Scenario: Edit a command field
- **WHEN** the user changes a command's prompt template or output target in the editor
- **THEN** the change is persisted immediately and used on the next firing

#### Scenario: Reorder and delete
- **WHEN** the user reorders or deletes commands in the editor
- **THEN** the band reflects the new order / removal on the next launcher open

### Requirement: Prompt template token resolution
A command's prompt template SHALL support tokens that are resolved at fire time from the captured context: `{input}` (the acquired input text), `{date}` (the current date/time), `{app}` (the captured front app's name), and `{url}` (the front document/page URL when available). Unknown tokens SHALL be left untouched, and a missing `{url}`/`{app}` SHALL resolve to an empty string rather than failing the command.

#### Scenario: Input token is substituted
- **WHEN** a command with template `"Fix the grammar:\n{input}"` is fired on selected text
- **THEN** the model receives the template with `{input}` replaced by the selected text

#### Scenario: Missing context token degrades to empty
- **WHEN** a template references `{url}` but the front app exposes no URL
- **THEN** `{url}` resolves to an empty string and the command still runs

### Requirement: Synthetic AI command band
When the AI commands opt-in is effective, the launcher SHALL present a band whose items are the configured AI commands, **built fresh on every launcher open** from the command store and **never written into the Favorites record**. The band SHALL render in the icon grid (icon + label, tinted per the command) and SHALL be absent entirely when the opt-in is off or no commands are configured.

#### Scenario: Band present only when opted in
- **WHEN** the AI commands opt-in is off
- **THEN** no AI command band appears in the launcher

#### Scenario: Band reflects current configuration
- **WHEN** the user edits commands and re-opens the launcher
- **THEN** the band is rebuilt from the current command list

#### Scenario: Commands render as grid items
- **WHEN** the AI command band is shown with several commands
- **THEN** each command renders as an icon-plus-label cell, navigable by the existing item stepping

### Requirement: Command input acquisition
When an AI command is fired, the system SHALL acquire its input according to the command's configured input source: `selection` reads the front app's selected text, `clipboard` reads the current clipboard, `screenRegion` captures a screen region for the vision model, and `none` supplies no input. If the configured source yields nothing (e.g. no selection), the system SHALL fall back where sensible (selection → clipboard) and, if no input can be obtained for a command that requires input, SHALL surface a clear "no input" state rather than running on empty.

#### Scenario: Selection source reads highlighted text
- **WHEN** a `selection` command is fired with text highlighted in the front app
- **THEN** the highlighted text is used as `{input}`

#### Scenario: Empty selection falls back to clipboard
- **WHEN** a `selection` command is fired with no current selection but text on the clipboard
- **THEN** the clipboard text is used as `{input}`

#### Scenario: No input available is surfaced
- **WHEN** an input-requiring command is fired and neither selection nor clipboard yields text
- **THEN** the preview shows a clear "no input" state and the model is not invoked

### Requirement: In-place output routing
For non-task output targets, after the model result is committed the system SHALL route it: `replaceSelection` replaces the front app's selected text (via selection replace when settable, else paste), `pasteAtCursor` pastes the result at the insertion point, and `previewOnly` shows the result without writing into the app. Output SHALL be delivered into the app that was frontmost when the launcher opened.

#### Scenario: Replace selection commits in place
- **WHEN** a `replaceSelection` command's streamed result is committed
- **THEN** the front app's selection is replaced by the result, in the app that was frontmost at open

#### Scenario: Preview-only never writes
- **WHEN** a `previewOnly` command's result is committed
- **THEN** the result is shown but nothing is written into the front app

### Requirement: Opt-in gates the band and the model
The AI command band, the model download, and model residency SHALL all be gated by a single "AI commands" opt-in that defaults to OFF. With the opt-in off, no model is downloaded or loaded, and the band does not appear.

#### Scenario: Off by default does nothing
- **WHEN** the app runs for the first time
- **THEN** the AI commands opt-in is off, no model is downloaded, and no AI command band appears

#### Scenario: Turning the opt-in off frees the model
- **WHEN** the user turns the opt-in off after using the feature
- **THEN** the band disappears and the resident model is evicted from memory
