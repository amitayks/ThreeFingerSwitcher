# tunable-settings — delta for refine-window-filtering

## ADDED Requirements

### Requirement: Per-app window listing rules

The system SHALL persist a per-app window-listing rule dictionary keyed by application identity (bundle identifier, falling back to executable name), with values `include`, `strict`, or `exclude`; absence of a key SHALL mean the app follows the global filtering policy. The dictionary SHALL default to empty, persist across launches via the standard settings store, and be cleared by reset-to-defaults.

#### Scenario: Rule persists across launches

- **WHEN** a per-app rule is set and the app relaunches
- **THEN** the rule is still in effect

#### Scenario: Reset clears the rules

- **WHEN** settings are reset to defaults
- **THEN** the per-app rule dictionary is empty and every app follows the global policy

#### Scenario: Absent key follows global policy

- **WHEN** an app has no entry in the dictionary
- **THEN** its windows are filtered by the global strict/relaxed policy alone
