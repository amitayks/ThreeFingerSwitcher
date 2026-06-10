## MODIFIED Requirements

### Requirement: Settings UI
The system SHALL provide the configuration UI to view and edit all tunables as the **Hub** window (its Overview and per-feature pages), reachable from the status menu. There SHALL be no separate Settings window; wherever this and other requirements refer to "the Settings UI," that UI is provided by the Hub.

#### Scenario: Open settings from menu
- **WHEN** the user opens configuration from the status menu
- **THEN** the Hub opens showing the tunables on their feature pages with their current values

#### Scenario: Reset to defaults
- **WHEN** the user chooses to reset
- **THEN** all tunables return to their default values

### Requirement: Diagnostics visibility preference and in-Settings setup access
The system SHALL expose a "show diagnostic tools" preference, off by default, that controls whether the diagnostic actions (write diagnostics, copy focus log) are available in the Hub's General page. It SHALL persist across launches and SHALL return to off on reset-to-defaults. The Hub SHALL additionally provide access to Setup & Permissions (its Setup page) and — when a Mission Control backup exists — restoring the native three-finger up/down (Mission Control) gesture.

#### Scenario: Diagnostics preference off by default
- **WHEN** the app runs for the first time
- **THEN** the show-diagnostics preference is off and the diagnostic actions are not shown in the Hub

#### Scenario: Diagnostics preference persists
- **WHEN** the user enables the show-diagnostics preference and relaunches
- **THEN** the preference remains enabled

#### Scenario: Reset turns diagnostics visibility off
- **WHEN** the user resets to defaults
- **THEN** the show-diagnostics preference returns to off

#### Scenario: Diagnostics appear in the Hub when enabled
- **WHEN** the user enables the show-diagnostics preference
- **THEN** the write-diagnostics and copy-focus-log actions appear on the Hub's General page

#### Scenario: Setup and Mission Control restore live in the Hub
- **WHEN** the user opens the Hub
- **THEN** it provides a Setup & Permissions page, and — when a Mission Control backup exists — an entry to restore the native three-finger up/down gesture

## REMOVED Requirements

### Requirement: AI command authoring is reachable from settings
**Reason**: AI commands are now authored inline on the Hub's Bands page as band items, not through a settings-reachable editor.
**Migration**: Open the Hub's Bands page to create/edit/reorder/delete AI commands; the AI feature page retains only enablement, model management, and model selection.
