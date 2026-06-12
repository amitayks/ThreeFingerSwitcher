# launch-items Specification

## Purpose

Define the data model for launch items and context bands: the heterogeneous item kinds, their stable identity and appearance, the fixed user-defined ordering of items and bands, the deterministic home cell, and versioned codable persistence.

## Requirements

### Requirement: Heterogeneous launch-item kinds
The system SHALL model a launch item as exactly one of: an application, a filesystem path, a URL, a Shortcuts.app shortcut, a script (shell, AppleScript, or a script file), or a preset (an ordered composite of other launch items). Each item SHALL carry a stable identity, a user-editable title, an icon, and a color tint. A URL item MAY additionally carry an optional handler application to open it with (else the system default) and an optional new-window preference (else reuse the existing window). Both URL fields SHALL be optional and default such that a record written before they existed decodes unchanged (no schema bump).

#### Scenario: Each kind is representable
- **WHEN** the user creates an app, a path, a URL, a shortcut, a script, or a preset item
- **THEN** the model stores that kind with its title, icon, and tint

#### Scenario: A URL carries an optional handler and window preference
- **WHEN** the user sets a link's "open with" app and/or its new-window preference
- **THEN** the model stores them on the URL item, and a legacy URL item without them still decodes with both defaulting to nil

#### Scenario: Preset references other items
- **WHEN** the user creates a preset from several existing items
- **THEN** the preset stores an ordered list of references to those items

### Requirement: Context bands with fixed user order
The system SHALL organize launch items into named, colored context bands. Items within a band SHALL be kept in an explicit user-defined order, and bands SHALL be kept in an explicit user-defined order. Neither items nor bands SHALL be reordered automatically by recency or frequency. The same item kind/target MAY appear in more than one band.

#### Scenario: Order is preserved
- **WHEN** the user arranges items in a band in a particular order
- **THEN** the launcher presents them in exactly that order on every activation

#### Scenario: No automatic reordering
- **WHEN** the user fires an item
- **THEN** the stored order of items and bands is unchanged

#### Scenario: Item appears in multiple bands
- **WHEN** the user adds the same app to two different bands
- **THEN** both bands list the app independently

### Requirement: Deterministic home cell
The system SHALL persist a designated home band and home column that the launcher uses as its entry point.

#### Scenario: Home cell persists
- **WHEN** the user has favorites configured and relaunches the app
- **THEN** the same home band and column are used as the launcher entry point

### Requirement: Versioned persistence
The system SHALL persist all bands, items, ordering, and the home cell as a single versioned, codable record that survives relaunch. The stored schema version SHALL allow forward migration of older records.

#### Scenario: Favorites survive relaunch
- **WHEN** the user configures bands and items and relaunches the app
- **THEN** the same bands, items, order, colors, and icons are restored

#### Scenario: Versioned record
- **WHEN** the favorites record is written
- **THEN** it includes a schema version that a future app version can migrate from
