# ai-command-catalog Specification

## Purpose
TBD - created by archiving change expand-ai-command-catalog. Update Purpose after archive.
## Requirements
### Requirement: Categorized AI command catalog
The system SHALL provide a curated **catalog** of ready-made `AICommand` presets, each a complete, fireable command (name, icon, tint, input source, prompt template, output target, and — where applicable — a runtime parameter). Every preset SHALL belong to exactly one **category**, and the catalog SHALL cover at least these categories: **Writing**, **Tone**, **Understand**, **Translate**, **Developer**, **Reply**, **Capture** (side-effecting tasks), **Vision** (screen-region), and **Format**. The catalog SHALL be the single source of the presets used both by the Bands-editor browser and by the fresh-install seed.

#### Scenario: Catalog spans the named categories
- **WHEN** the catalog is enumerated
- **THEN** it contains presets grouped under Writing, Tone, Understand, Translate, Developer, Reply, Capture, Vision, and Format, and every preset declares its category

#### Scenario: Each preset is a complete, fireable command
- **WHEN** any catalog preset is inspected
- **THEN** it carries a name, icon, input source, prompt template, and output target sufficient to fire without further editing

### Requirement: Catalog browser source in the Bands editor
The Bands editor's AI source SHALL be a **catalog browser** (mirroring the system-actions browser): it SHALL list presets grouped by category, and SHALL let the user **add a single preset** to the active band in one click. The browser SHALL also let the user **add a whole category as a band** (creating a new band named after the category, carrying the **category's color**, populated with that category's presets); adding a category SHALL **append** a new band even when a band of the same name already exists (it does not merge into or replace the existing one). A trailing **"Custom command"** entry SHALL remain that adds a blank, editable AI command (preserving the prior blank-then-edit flow). Adding a preset or category SHALL NOT require the AI opt-in.

#### Scenario: Browse by category and add one preset
- **WHEN** the user opens the AI source, picks a category, and clicks a preset
- **THEN** that preset is added as an `.aiCommand` item to the active band and selected for editing

#### Scenario: Add a whole category as a band
- **WHEN** the user chooses "add as a band" for a category
- **THEN** a new band named after the category, carrying the category's color, is created and populated with that category's presets

#### Scenario: Adding a category appends rather than merging
- **WHEN** the user adds a category as a band and a band of the same name already exists
- **THEN** a new band is appended (the existing same-named band is not merged into or replaced)

#### Scenario: Custom blank command still available
- **WHEN** the user chooses the "Custom command" entry
- **THEN** a blank, editable AI command is added (input `selection`, template `{input}`, output preview-only) as before

#### Scenario: Browser works regardless of the AI opt-in
- **WHEN** the AI opt-in is off and the user adds a preset from the catalog
- **THEN** the command is added normally (the opt-in gates only the model, never authoring or visibility)

### Requirement: Added presets are independent editable copies
Adding a catalog preset SHALL produce an **independent copy**: the added command SHALL receive a freshly minted identifier (the catalog template's identifier is a stencil, never the live item's id), so the same preset MAY be added multiple times without identifier collision, and editing an added command SHALL NOT mutate the catalog or any other added copy.

#### Scenario: The same preset can be added twice
- **WHEN** the user adds the same catalog preset to a band twice
- **THEN** two items exist with distinct identifiers, each independently editable

#### Scenario: Editing an added command does not change the catalog
- **WHEN** the user edits a command that was added from the catalog
- **THEN** the catalog preset and any other added copies are unchanged

### Requirement: Fresh-install seed is drawn from the catalog
The fresh-install "AI" band SHALL be composed from a **curated subset of the catalog** rather than a separate hand-maintained list, so the seeded defaults and the browsable catalog stay consistent. The seed SHALL remain a single, curated band (not the entire catalog), and SHALL only apply on a fresh install (the existing migration/idempotency guard is unchanged — an upgrading user is not re-seeded).

#### Scenario: Fresh install seeds a curated catalog subset
- **WHEN** the app is first installed with no prior AI commands
- **THEN** the seeded "AI" band's commands are drawn from the catalog and form one curated band, not the whole catalog

#### Scenario: Upgrading users are not re-seeded
- **WHEN** an existing user who already has AI commands upgrades
- **THEN** their bands are left untouched and the grown seed is not applied

### Requirement: Clipboard-image vision presets
The catalog SHALL include at least one **clipboard-image** vision preset whose input source is `clipboardImage` and whose output target is `previewOnly`, so a user can analyze an image already on the clipboard without capturing the screen. These presets SHALL belong to the **Vision** category alongside the screen-region presets, and each SHALL be a complete, fireable command (name, icon, the `clipboardImage` input, a prompt template, and `previewOnly` output) requiring no further editing.

#### Scenario: Catalog offers a clipboard-image vision preset
- **WHEN** the catalog is enumerated
- **THEN** it contains at least one Vision-category preset whose input source is `clipboardImage`

#### Scenario: Clipboard-image preset is complete and fireable
- **WHEN** a clipboard-image vision preset is inspected
- **THEN** it carries a name, icon, the `clipboardImage` input source, a prompt template, and `previewOnly` output sufficient to fire without further editing

