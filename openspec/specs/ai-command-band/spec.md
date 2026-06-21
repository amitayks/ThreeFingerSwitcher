# ai-command-band Specification

## Purpose

Define the AI command feature surfaced in the launcher: a Codable AI-command value model persisted as a first-class band item inside Favorites (folded in from the former separate store), inline authoring on the Hub's Bands page, prompt-template token resolution, command input acquisition with sensible fallback, in-place output routing into the captured front app, a one-time migration of legacy commands into a normal "AI" band, and a single opt-in that gates the on-device model's download/residency (but never the visibility of AI items).
## Requirements
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

### Requirement: Migration of existing AI commands into the band model
On upgrade from a version that stored AI commands separately, the system SHALL perform a one-time, idempotent migration that imports the previously stored commands into a normal, editable context band (named "AI", carrying the prior AI-band color) appended to the Favorites record, **preserving each command's identifier and order**. The migration SHALL run at most once (guarded by the Favorites schema version), SHALL retire the old separate storage only after the new record is written successfully, and SHALL NOT duplicate commands on subsequent launches. A fresh install (no prior commands) SHALL instead seed the default "AI" band as part of normal seeding; an upgrading user who never opted in SHALL likewise get the default "AI" band seeded.

#### Scenario: Existing commands move into an editable AI band
- **WHEN** a user who had configured AI commands upgrades to the band model
- **THEN** their commands appear as items of a normal "AI" band in the Favorites record, with identifiers and order preserved

#### Scenario: Migration is idempotent
- **WHEN** the migrated app is relaunched
- **THEN** the commands are not imported again and no duplicate "AI" band is created

#### Scenario: Fresh install seeds the default AI band
- **WHEN** the app is first installed with no prior AI commands
- **THEN** a default "AI" band with the seeded starter commands is created as part of normal seeding

### Requirement: Prompt template token resolution
A command's prompt template SHALL support tokens that are resolved at fire time from the captured context: `{input}` (the acquired input text), `{date}` (the current date/time), `{app}` (the captured front app's name), `{url}` (the front document/page URL when available), and `{lang}` (the command's **active runtime language** — the canvas selection, falling back to the persisted last choice, falling back to the command's language-parameter default). Unknown tokens SHALL be left untouched, and a missing `{url}`/`{app}` SHALL resolve to an empty string rather than failing the command. A `{lang}` token on a command that declares no language parameter SHALL resolve to an empty string rather than failing.

#### Scenario: Input token is substituted
- **WHEN** a command with template `"Fix the grammar:\n{input}"` is fired on selected text
- **THEN** the model receives the template with `{input}` replaced by the selected text

#### Scenario: Missing context token degrades to empty
- **WHEN** a template references `{url}` but the front app exposes no URL
- **THEN** `{url}` resolves to an empty string and the command still runs

#### Scenario: Language token resolves to the active language
- **WHEN** a translate command with template `"Translate to {lang}:\n{input}"` and active language "Hebrew" is fired
- **THEN** the model receives the template with `{lang}` replaced by "Hebrew"

#### Scenario: Language token without a language parameter degrades to empty
- **WHEN** a command that declares no language parameter references `{lang}`
- **THEN** `{lang}` resolves to an empty string and the command still runs

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

### Requirement: In-place output routing
For non-task output targets, after the model result is committed the system SHALL route it: `replaceSelection` replaces the front app's selected text (via selection replace when settable, else paste), `pasteAtCursor` pastes the result at the insertion point, and `previewOnly` shows the result without writing into the app. Output SHALL be delivered into the app that was frontmost when the launcher opened.

#### Scenario: Replace selection commits in place
- **WHEN** a `replaceSelection` command's streamed result is committed
- **THEN** the front app's selection is replaced by the result, in the app that was frontmost at open

#### Scenario: Preview-only never writes
- **WHEN** a `previewOnly` command's result is committed
- **THEN** the result is shown but nothing is written into the front app

### Requirement: Opt-in gates the model, not the visibility of AI items
The AI commands opt-in SHALL gate the on-device model's **download and residency** only; it SHALL default to OFF, and with it off no model is downloaded or loaded. The opt-in SHALL NOT hide AI-command items from the launcher: AI-command items SHALL always appear and be fireable regardless of the opt-in. When AI is off (or the selected model is not yet available), firing an AI-command item SHALL open its preview canvas in an availability state offering to enable/download rather than silently doing nothing (see launcher-overlay). Turning the opt-in off after use SHALL evict the resident model from memory.

#### Scenario: Off by default downloads no model
- **WHEN** the app runs for the first time
- **THEN** the AI commands opt-in is off and no model is downloaded or loaded

#### Scenario: AI items appear even when the opt-in is off
- **WHEN** the opt-in is off and the launcher is opened on a band containing AI commands
- **THEN** the AI-command items still appear and can be fired

#### Scenario: Turning the opt-in off frees the model
- **WHEN** the user turns the opt-in off after using the feature
- **THEN** the resident model is evicted from memory (the AI items remain visible but inert until re-enabled)

### Requirement: Runtime-adjustable command parameter
A command MAY declare a **runtime parameter** that is chosen at fire time rather than baked into the template. In v1 the only runtime parameter SHALL be a **target language** (`language(default:)`). When a command declares a language parameter, its **active language** SHALL be resolved into the `{lang}` token at fire time, and the system SHALL expose the parameter for in-canvas adjustment (see launcher-overlay). Re-resolving the parameter SHALL re-run the command (see launcher-overlay) using the existing cancellable generation. The runtime parameter SHALL be optional and default to absent, so commands without one behave exactly as before.

#### Scenario: A command without a runtime parameter is unchanged
- **WHEN** a command that declares no runtime parameter is fired
- **THEN** it resolves and runs exactly as before, with no parameter UI

#### Scenario: A language-parameter command resolves its active language
- **WHEN** a command declaring `language(default: "English")` is fired with no prior choice
- **THEN** its active language is "English" and `{lang}` resolves to "English"

### Requirement: Per-command runtime-parameter persistence
The system SHALL persist the **last chosen value** of a command's runtime parameter **per command** (keyed by the command's identifier) and use it as the **default active value on the next run** of that command. Persistence SHALL NOT mutate the stored command (so seeds, catalog presets, and band edits are unaffected); it SHALL be an out-of-band preference that survives relaunch. The command's declared default SHALL be the cold-start fallback when no value has been chosen yet. The store SHALL be **best-effort**: an entry whose command no longer exists (deleted, or a never-re-added copy) MAY be pruned and SHALL otherwise be ignored, and a persisted entry SHALL never block deleting its command.

#### Scenario: A chosen language is remembered next run
- **WHEN** the user picks "Spanish" while running a translate command, then fires the same command again later
- **THEN** the command's initial active language is "Spanish"

#### Scenario: Two language commands remember independently
- **WHEN** the user sets one command to "Hebrew" and another to "French"
- **THEN** each command re-opens with its own remembered language

#### Scenario: Persistence does not change the stored command
- **WHEN** a runtime-parameter value is chosen and persisted
- **THEN** the stored `AICommand` (and any catalog/seed source it came from) is unchanged; only the out-of-band preference records the choice

#### Scenario: A deleted command's persisted value is harmless
- **WHEN** a command with a persisted runtime-parameter value is deleted
- **THEN** the deletion succeeds and the now-orphaned persisted entry is ignored (and MAY be pruned), never resurfacing on an unrelated command

### Requirement: Screen-region commands acquire via the region picker before the canvas
When a `screenRegion` command is fired, the system SHALL acquire its image through the interactive region picker **before** opening the preview canvas: the launcher is dismissed to reveal the desktop, the user designates a region, and only the captured image is then supplied to the command. The executor SHALL accept this **pre-supplied** image and SHALL NOT perform its own additional screen capture for that command. If the pick is **cancelled** (a click without a drag), the command SHALL **abort** — no preview canvas opens and the model is not invoked. A cancelled pick is distinct from the "no input" state: it is a deliberate user abort, not a missing-input failure, and SHALL NOT surface a "no input" error.

#### Scenario: The picker runs before the canvas opens
- **WHEN** a `screenRegion` command is fired
- **THEN** the launcher is dismissed and the region picker runs first; the preview canvas opens only after a region is captured

#### Scenario: Executor uses the pre-supplied image
- **WHEN** a region is captured for a `screenRegion` command
- **THEN** the executor fires the request with that captured image and does not perform an additional screen capture

#### Scenario: Cancelled pick aborts the command
- **WHEN** the region pick is cancelled (a click without a drag)
- **THEN** no preview canvas opens and the model is not invoked, and no "no input" failure is shown

