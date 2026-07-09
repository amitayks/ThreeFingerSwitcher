## MODIFIED Requirements

### Requirement: AI command value model and persistence
The system SHALL define an AI command as a Codable value type carrying: a stable identifier, a display name, an icon and tint, an **input capability set** (`inputs`: a set drawn from `selection` | `clipboard` | `clipboardImage` | `screenRegion`; the empty set means "no input needed"), a **prompt template** string, an **output capability set** (`outputs`: a set drawn from `replaceSelection` | `pasteAtCursor` | `previewOnly` | `runTask(TaskKind)` | `sendTo(Destination)`), a **model selector** (v1: on-device Gemma 4), and a **confirmBeforeRun** flag. A freshly created command SHALL default both sets **all-on** for its family: `inputs = {selection, clipboard, clipboardImage}` and `outputs = {replaceSelection, pasteAtCursor, previewOnly}`. A command's **potential** required capabilities (`requiredCapabilities`) SHALL be the **union** over its enabled inputs — `vision` when any enabled input is an image source (`clipboardImage`, `screenRegion`), and `text` otherwise — and this union is an informational hint only; it SHALL NOT be the value used to request the model (see "Command input acquisition"). Persistence SHALL migrate legacy single-valued `input`/`output` fields into these sets on decode, behavior-preservingly (`selection`→`{selection, clipboard}`, `replaceSelection`→`{replaceSelection, pasteAtCursor}`, other scalars→their singleton set, `none`→`{}`), preserving the identifier. An AI command SHALL remain a first-class, persisted **band item**: stored **inside the Favorites record** as the item of a context band, persisting across launches, applying immediately when changed, and movable between bands like any other item. Its stable identifier SHALL be preserved across edits and migration.

#### Scenario: Commands persist across launches
- **WHEN** the user creates AI commands and relaunches the app
- **THEN** the same commands, in the same order within their bands, are present

#### Scenario: Commands are stored as Favorites band items
- **WHEN** AI commands exist and the Favorites record is inspected
- **THEN** the commands are present as items of context bands (they are no longer kept in a separate store)

#### Scenario: Legacy scalar input/output migrate to capability sets
- **WHEN** a command persisted with the old single `input: selection` / `output: replaceSelection` fields is decoded
- **THEN** it decodes with `inputs = {selection, clipboard}` and `outputs = {replaceSelection, pasteAtCursor}`, preserving its identifier and prior effective behavior

#### Scenario: A new command defaults every capability on
- **WHEN** a blank AI command is created
- **THEN** its `inputs` are `{selection, clipboard, clipboardImage}` and its in-place `outputs` are `{replaceSelection, pasteAtCursor, previewOnly}`

#### Scenario: confirmBeforeRun defaults on for side-effecting output but is honored
- **WHEN** a command whose outputs contain a side-effecting `runTask`/`sendTo` is created without an explicit choice
- **THEN** its `confirmBeforeRun` defaults to true; if the user later sets it false, that stored value is honored at run time (not overridden)

#### Scenario: requiredCapabilities is the union hint, not the model request
- **WHEN** a command with `inputs = {selection, clipboardImage}` is inspected
- **THEN** its `requiredCapabilities` union includes both `text` and `vision`, but this value does not by itself force a vision model — the model is requested from the input resolved at fire time

### Requirement: Command input acquisition
When an AI command is fired, the system SHALL acquire its input by **resolving the live environment against the command's enabled input capabilities**, not from a single stored source. The executor SHALL activate the highest-priority **enabled** channel that is live, in the order `selection ▸ clipboard-text ▸ clipboard-image`: a non-empty selection wins; else non-empty clipboard text; else a decodable clipboard image (supplied as the request's PNG image input). The **resolved** channel SHALL be remembered to drive both the model capability and the commit behavior. The model requested SHALL be a **vision** model only when the resolved channel is an image, and a **text** model otherwise — so capability follows the actual input, not the authored superset. A command whose enabled inputs are **empty** requires no input (a standalone prompt). A command whose enabled inputs contain `screenRegion` SHALL instead be acquired **region-first** via the interactive picker before the canvas (unchanged), and SHALL NOT blend region capture into the ambient cascade. If a command requires input but **no** enabled channel is live — no selection, no clipboard text, no clipboard image — the system SHALL surface a clear "no input" state and SHALL NOT invoke the model.

#### Scenario: Selection wins when text is highlighted
- **WHEN** a command with `selection` enabled is fired with text highlighted in the front app
- **THEN** the highlighted text is used as `{input}` and the resolved channel is the selection

#### Scenario: Empty selection cascades to the clipboard text
- **WHEN** a command with `selection` and `clipboard` enabled is fired with no current selection but text on the clipboard
- **THEN** the clipboard text is used as `{input}` and the resolved channel is the clipboard (so commit will paste, not replace)

#### Scenario: No text anywhere cascades to a clipboard image
- **WHEN** a command with `clipboardImage` enabled is fired with no selection and no clipboard text, but an image on the clipboard
- **THEN** the clipboard image is supplied as the request's image input, a vision model is requested, and the vision result streams into the canvas

#### Scenario: A disabled channel is skipped
- **WHEN** a command with `selection` disabled (only `clipboard` enabled) is fired while text is selected
- **THEN** the selection is ignored and the clipboard text is used

#### Scenario: No live channel surfaces no input
- **WHEN** an input-requiring command is fired and none of its enabled channels is live
- **THEN** the preview shows a clear "no input" state and the model is not invoked

### Requirement: In-place output routing
For a command whose outputs are in-place (no `runTask`/`sendTo`), after the model result is committed the system SHALL route it by the **resolved input channel**, honoring the enabled output capabilities: when the resolved input was a **selection** and `replaceSelection` is enabled, it SHALL replace the front app's selected text (via selection replace when settable, else paste); otherwise when `pasteAtCursor` is enabled it SHALL paste the result at the insertion point; otherwise when only `previewOnly` is enabled it SHALL write nothing. Output SHALL be delivered into the app that was frontmost when the launcher opened. A command whose outputs contain a `runTask`/`sendTo` SHALL route through the side-effecting accept-step/execute flow unchanged.

#### Scenario: Selection input commits as a replace
- **WHEN** an in-place command resolved its input from the selection and `replaceSelection` is enabled, and its result is committed
- **THEN** the front app's selection is replaced by the result, in the app that was frontmost at open

#### Scenario: Clipboard input commits as a paste
- **WHEN** an in-place command resolved its input from the clipboard (no selection) and `pasteAtCursor` is enabled, and its result is committed
- **THEN** the result is pasted at the insertion point (the selection is not touched)

#### Scenario: Preview-only never writes
- **WHEN** a command whose only enabled output is `previewOnly` has its result committed
- **THEN** the result is shown but nothing is written into the front app
