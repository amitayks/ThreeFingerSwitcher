## MODIFIED Requirements

### Requirement: AI command value model and persistence
The system SHALL define an AI command as a Codable value type carrying: a stable identifier, a display name, an icon and tint, an **input source** (`selection` | `clipboard` | `clipboardImage` | `screenRegion` | `none`), a **prompt template** string, an **output target** (`replaceSelection` | `pasteAtCursor` | `previewOnly` | `task(TaskKind)` | `sendTo(Destination)`), a **model selector** (v1: on-device Gemma 4), and a **confirmBeforeRun** flag. The **image** input sources (`clipboardImage`, `screenRegion`) SHALL require a vision-capable model (their `requiredCapabilities` include `vision`); the text sources (`selection`, `clipboard`, `none`) SHALL require only the text capability — this mapping SHALL be derived statically from the input source and SHALL NOT depend on runtime clipboard contents. An AI command SHALL be a first-class, persisted **band item**: it is stored **inside the Favorites record** as the item of a context band, persists across launches, applies immediately when changed, and SHALL be movable between bands like any other item. Its stable identifier SHALL be preserved across edits and the migration into the band model (the identifier keys the executor and the UI).

#### Scenario: Commands persist across launches
- **WHEN** the user creates AI commands and relaunches the app
- **THEN** the same commands, in the same order within their bands, are present

#### Scenario: Commands are stored as Favorites band items
- **WHEN** AI commands exist and the Favorites record is inspected
- **THEN** the commands are present as items of context bands (they are no longer kept in a separate store)

#### Scenario: confirmBeforeRun defaults on for side-effecting output but is honored
- **WHEN** a command with a side-effecting task or send-to destination is created without an explicit choice
- **THEN** its `confirmBeforeRun` defaults to true; if the user later sets it false, that stored value is honored at run time (not overridden)

#### Scenario: A clipboard-image command requires a vision-capable model
- **WHEN** a command whose input source is `clipboardImage` is inspected for its required capabilities
- **THEN** the required capabilities include `vision` (statically, the same as a `screenRegion` command), so model selection routes it to a vision-capable model

### Requirement: Command input acquisition
When an AI command is fired, the system SHALL acquire its input according to the command's configured input source: `selection` reads the front app's selected text, `clipboard` reads the current clipboard text, `clipboardImage` reads the current clipboard **image** (the live pasteboard image, normalized to PNG) as the request's image input, `screenRegion` captures a screen region for the vision model, and `none` supplies no input. If a **text** source yields nothing the system SHALL fall back where sensible (selection → clipboard). An **image** source (`clipboardImage`, `screenRegion`) SHALL NOT fall back to text. If no input can be obtained for a command that requires input — including a `clipboardImage` command fired with no image on the clipboard — the system SHALL surface a clear "no input" state rather than running the model on empty.

#### Scenario: Selection source reads highlighted text
- **WHEN** a `selection` command is fired with text highlighted in the front app
- **THEN** the highlighted text is used as `{input}`

#### Scenario: Empty selection falls back to clipboard
- **WHEN** a `selection` command is fired with no current selection but text on the clipboard
- **THEN** the clipboard text is used as `{input}`

#### Scenario: Clipboard-image source reads the pasteboard image
- **WHEN** a `clipboardImage` command is fired with an image on the clipboard
- **THEN** the clipboard image (as PNG bytes) is supplied to the runtime as the request's image input and the vision result streams into the canvas

#### Scenario: Clipboard with no image surfaces no input
- **WHEN** a `clipboardImage` command is fired and the clipboard holds no image
- **THEN** the preview shows a clear "no input" state and the model is not invoked (no fallback to text)

#### Scenario: No input available is surfaced
- **WHEN** an input-requiring command is fired and neither selection nor clipboard yields text
- **THEN** the preview shows a clear "no input" state and the model is not invoked
