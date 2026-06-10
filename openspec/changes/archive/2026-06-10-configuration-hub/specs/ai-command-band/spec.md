## MODIFIED Requirements

### Requirement: AI command value model and persistence
The system SHALL define an AI command as a Codable value type carrying: a stable identifier, a display name, an icon and tint, an **input source** (`selection` | `clipboard` | `screenRegion` | `none`), a **prompt template** string, an **output target** (`replaceSelection` | `pasteAtCursor` | `previewOnly` | `task(TaskKind)` | `sendTo(Destination)`), a **model selector** (v1: on-device Gemma 4), and a **confirmBeforeRun** flag. An AI command SHALL be a first-class, persisted **band item**: it is stored **inside the Favorites record** as the item of a context band, persists across launches, applies immediately when changed, and SHALL be movable between bands like any other item. Its stable identifier SHALL be preserved across edits and the migration into the band model (the identifier keys the executor and the UI).

#### Scenario: Commands persist across launches
- **WHEN** the user creates AI commands and relaunches the app
- **THEN** the same commands, in the same order within their bands, are present

#### Scenario: Commands are stored as Favorites band items
- **WHEN** AI commands exist and the Favorites record is inspected
- **THEN** the commands are present as items of context bands (they are no longer kept in a separate store)

#### Scenario: confirmBeforeRun defaults on for side-effecting output but is honored
- **WHEN** a command with a side-effecting task or send-to destination is created without an explicit choice
- **THEN** its `confirmBeforeRun` defaults to true; if the user later sets it false, that stored value is honored at run time (not overridden)

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

## ADDED Requirements

### Requirement: Migration of existing AI commands into the band model
On upgrade from a version that stored AI commands separately, the system SHALL perform a one-time, idempotent migration that imports the previously stored commands into a normal, editable context band (named "AI", carrying the prior AI-band color) appended to the Favorites record, **preserving each command's identifier and order**. The migration SHALL run at most once (guarded by the Favorites schema version), SHALL retire the old separate storage only after the new record is written successfully, and SHALL NOT duplicate commands on subsequent launches. A fresh install (no prior commands) SHALL instead seed the default "AI" band as part of normal seeding.

#### Scenario: Existing commands move into an editable AI band
- **WHEN** a user who had configured AI commands upgrades to the band model
- **THEN** their commands appear as items of a normal "AI" band in the Favorites record, with identifiers and order preserved

#### Scenario: Migration is idempotent
- **WHEN** the migrated app is relaunched
- **THEN** the commands are not imported again and no duplicate "AI" band is created

#### Scenario: Fresh install seeds the default AI band
- **WHEN** the app is first installed with no prior AI commands
- **THEN** a default "AI" band with the seeded starter commands is created as part of normal seeding

## REMOVED Requirements

### Requirement: Authoring AI commands in Settings
**Reason**: The separate Settings-reachable AI-command editor is removed; AI commands are authored and edited inline on the Hub's Bands page like any other band item (see favorites-editor).
**Migration**: Create, edit, reorder, and delete AI commands on the Bands page; edits persist into the Favorites record immediately. Existing commands are migrated into a normal "AI" band.

### Requirement: Synthetic AI command band
**Reason**: AI commands are no longer projected into a synthetic, opt-in-gated band built fresh per launcher open; they are persisted, first-class band items that can live in any band.
**Migration**: Existing commands are migrated into a normal "AI" band; thereafter the launcher renders AI-command items from the Favorites record like any other item, and the opt-in no longer controls their presence (only the model's download/residency).
