## MODIFIED Requirements

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

## ADDED Requirements

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
