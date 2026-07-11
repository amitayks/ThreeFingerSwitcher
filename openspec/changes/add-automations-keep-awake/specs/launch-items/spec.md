## MODIFIED Requirements

### Requirement: Heterogeneous launch-item kinds
The system SHALL model a launch item as exactly one of: an application, a filesystem path, a URL, a Shortcuts.app shortcut, a script (shell, AppleScript, or a script file), a preset (an ordered composite of other launch items), or an **automation** (a toggle-style item that starts/stops a persistent mode; see the `automations` capability). Each item SHALL carry a stable identity, a user-editable title, an icon, and a color tint. A URL item MAY additionally carry an optional handler application to open it with (else the system default) and an optional new-window preference (else reuse the existing window). Both URL fields SHALL be optional and default such that a record written before they existed decodes unchanged (no schema bump). An automation item SHALL carry which automation it is plus an optional per-automation setting (e.g. Keep Awake's dim level), encoded such that a record written before automations (or before the setting) existed decodes unchanged (no schema bump).

#### Scenario: Each kind is representable
- **WHEN** the user creates an app, a path, a URL, a shortcut, a script, a preset, or an automation item
- **THEN** the model stores that kind with its title, icon, and tint

#### Scenario: URL carries optional handler and window preference
- **WHEN** the user sets a link's "open with" app and/or its new-window preference
- **THEN** the model stores those optional fields, and a link without them still decodes

#### Scenario: Preset stores an ordered reference list
- **WHEN** the user creates a preset from several existing items
- **THEN** the preset stores an ordered list of references to those items

#### Scenario: Automation item decodes forward-compatibly
- **WHEN** favorites saved before automations existed are loaded
- **THEN** they decode unchanged, and a saved automation item round-trips to the same automation
