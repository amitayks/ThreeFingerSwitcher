## ADDED Requirements

### Requirement: Skills are declarative, user-authorable files
Each AI verb SHALL be expressible as a **skill file**: a declarative, human-editable text file (one file per action, named for the action, e.g. `create-meeting-in-gcal.skill.md`) that externalizes everything a command carries — a stable **id**, a **title**, a router-facing **summary** (a one-line *when-to-use* description), **keywords**, an **input source**, a **prompt template**, an **output/sink binding**, and optional **runtime parameter**, **reasoning override**, **tool allow-list**, and **Claude-handoff** block. A skill file SHALL parse into a pure value model (a `SkillManifest`) that reuses the existing command value model for input/template/output/parameter semantics, so a skill behaves identically to an equivalent command when fired. A skill file SHALL require **no code change and no rebuild** to add or edit.

#### Scenario: A skill file declares a complete verb
- **WHEN** a skill file is parsed
- **THEN** it yields a manifest carrying an id, title, router summary, input source, prompt template, and output/sink binding sufficient to fire without further editing

#### Scenario: Adding a skill needs no code
- **WHEN** a user adds a valid skill file to the user skills folder
- **THEN** the skill becomes available without recompiling or reinstalling the app

#### Scenario: A skill's prompt template resolves identically to a command
- **WHEN** a skill's prompt template containing `{input}`, `{date}`, `{app}`, `{url}`, or `{lang}` is resolved against a fire context
- **THEN** the resolution is identical to the existing command template resolution (unknown tokens pass through, a missing language resolves to empty)

### Requirement: Skills folder, validation, and built-in / user coexistence
The system SHALL load skills from two locations: **built-in skills** shipped read-only inside the app bundle, and **user skills** in a writable folder under Application Support (created on first run). Each file SHALL be **validated at load**; a malformed skill (missing front-matter or a required field, an unknown input/output value, a malformed sink, an unparseable template) SHALL be reported as a **bounded, non-blocking problem** (a clean headline) and excluded from the index while the rest of the corpus loads — never a crash and never a silent drop. Built-in and user skills SHALL coexist; a **user skill whose id matches a built-in SHALL shadow** the built-in (the user file wins), giving a no-code path to override a shipped skill. Loading SHALL require **no new permission**.

#### Scenario: Built-in and user skills both load
- **WHEN** the skill store loads
- **THEN** the built-in skills and any user skills are both present in the index

#### Scenario: A user skill shadows a built-in of the same id
- **WHEN** a user skill file declares the same id as a built-in skill
- **THEN** the user skill replaces the built-in (its body and origin are used) and the built-in is not also listed

#### Scenario: A malformed skill is reported, not fatal
- **WHEN** one skill file is malformed
- **THEN** that file is reported as a single bounded problem (clean headline, raw detail only in logs/opt-in details), every other skill still loads, and the app does not crash or block

#### Scenario: Two user skills share an id
- **WHEN** two user skill files declare the same id
- **THEN** one wins deterministically and the other is reported as a duplicate-id problem

### Requirement: A skill projects to a routing tool descriptor
Each skill SHALL project to a **tool descriptor** the router can scan: the descriptor's name SHALL be the skill id, its summary SHALL be the skill's router-facing one-line description, its arguments schema SHALL be the skill's parsed-action schema (the existing per-task structured schema for a side-effecting sink, or a minimal text-result schema for an in-place sink), and its **write policy** SHALL default to **confirm** when the skill's output is side-effecting (and otherwise **auto**), mirroring the existing confirm-before-run default. Invoking a skill SHALL resolve its template, call the model, and route the result to the skill's bound sink via the existing task dispatch, producing an observable step outcome (done / declined / failed). A declined or failed invocation SHALL NOT report a false success.

#### Scenario: A side-effecting skill projects a confirm-tier descriptor with its task schema
- **WHEN** a skill bound to a side-effecting sink (e.g. add-to-calendar) is projected
- **THEN** its descriptor carries the corresponding parsed-action schema and a confirm write policy

#### Scenario: An in-place skill projects an auto-tier descriptor
- **WHEN** a skill bound to an in-place sink (e.g. replace-selection) is projected
- **THEN** its descriptor carries a text-result schema and an auto write policy

#### Scenario: An invoked skill that the model declines reports a decline, not a done
- **WHEN** a side-effecting skill is invoked on input the model declines as not applicable
- **THEN** the step outcome is a decline with a reason, no side effect is dispatched, and no false success is reported

## MODIFIED Requirements

### Requirement: Categorized AI command catalog
The system SHALL provide a curated **catalog** of ready-made command presets, each a complete, fireable command (name, icon, tint, input source, prompt template, output target, and — where applicable — a runtime parameter). Every preset SHALL belong to exactly one **category**, and the catalog SHALL cover at least these categories: **Writing**, **Tone**, **Understand**, **Translate**, **Developer**, **Reply**, **Capture** (side-effecting tasks), **Vision** (screen-region), and **Format**. The catalog SHALL be **derived from the built-in skill files** rather than a separately maintained in-code array: the in-code catalog is a **projection** over the built-in skills (grouping them by category, preserving each category's tint and section glyph and the per-category command order), so the skill files are the single source of truth and the catalog and the router never diverge. The projected catalog SHALL remain the single source of the presets used both by the Bands-editor browser and by the fresh-install seed.

#### Scenario: Catalog spans the named categories
- **WHEN** the catalog is enumerated
- **THEN** it contains presets grouped under Writing, Tone, Understand, Translate, Developer, Reply, Capture, Vision, and Format, and every preset declares its category

#### Scenario: Each preset is a complete, fireable command
- **WHEN** any catalog preset is inspected
- **THEN** it carries a name, icon, input source, prompt template, and output target sufficient to fire without further editing

#### Scenario: The catalog is a projection over the built-in skills
- **WHEN** the catalog is enumerated
- **THEN** every preset corresponds to a built-in skill file, grouped by its category, with the category's tint and section glyph preserved — and editing a built-in skill file changes the corresponding catalog preset

### Requirement: Fresh-install seed is drawn from the catalog
The fresh-install "AI" band SHALL be composed from a **curated subset of the catalog** (which is itself projected from the built-in skills) rather than a separate hand-maintained list, so the seeded defaults, the browsable catalog, and the skill files all stay consistent. The seed SHALL remain a single, curated band (not the entire catalog), SHALL preserve the existing curated subset and its order, and SHALL only apply on a fresh install (the existing migration/idempotency guard is unchanged — an upgrading user is not re-seeded and no persisted band is rewritten by the move to skill files).

#### Scenario: Fresh install seeds a curated catalog subset
- **WHEN** the app is first installed with no prior AI commands
- **THEN** the seeded "AI" band's commands are drawn from the catalog (projected from the built-in skills) and form one curated band, not the whole catalog

#### Scenario: Upgrading users are not re-seeded or rewritten
- **WHEN** an existing user who already has AI commands upgrades to the skill-files build
- **THEN** their bands are left untouched, no persisted band item is rewritten, and the grown seed is not applied
