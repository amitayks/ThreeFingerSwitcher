# tunable-settings Specification

## Purpose

Define the settings model, persistence, defaults, and Settings UI for the switcher's sensitivity, stepping, and behavior tunables.

## Requirements

### Requirement: Tunable gesture parameters
The system SHALL expose tunable parameters with sensible defaults: activation threshold, axis-lock ratio, step distance ("one window per N"), wrap-vs-clamp at list ends, direction (natural/reverse), velocity smoothing factor, and exact-three-fingers requirement.

#### Scenario: Defaults applied on first run
- **WHEN** the app runs for the first time
- **THEN** all tunables have sensible default values and the switcher is usable without configuration

#### Scenario: Changing step distance changes stepping
- **WHEN** the user increases the step distance
- **THEN** more finger travel is required to advance the selection by one window

#### Scenario: Direction inversion
- **WHEN** the user sets direction to reverse
- **THEN** sliding right moves the selection in the opposite direction from the natural setting

### Requirement: Persisted settings
The system SHALL persist settings across launches and apply them immediately when changed.

#### Scenario: Settings survive restart
- **WHEN** the user changes a setting and relaunches the app
- **THEN** the changed value is retained

#### Scenario: Live application
- **WHEN** the user changes a tunable while the app is running
- **THEN** the new value takes effect on the next gesture without requiring a restart

### Requirement: Settings UI
The system SHALL provide a Settings UI to view and edit all tunables, reachable from the status menu.

#### Scenario: Open settings from menu
- **WHEN** the user selects Settings from the status menu
- **THEN** a Settings window opens showing all tunables with their current values

#### Scenario: Reset to defaults
- **WHEN** the user chooses to reset
- **THEN** all tunables return to their default values

### Requirement: Vertical row-switching tunables
The system SHALL expose tunable parameters for vertical Space-row switching: a row-step distance (vertical travel per row step, defaulting larger than the horizontal step distance) and a reverse-vertical-direction toggle. Both SHALL persist and apply on the next gesture, and appear in the Settings UI.

#### Scenario: Row-step distance defaults larger than horizontal step
- **WHEN** the app runs for the first time
- **THEN** the row-step distance default is larger than the horizontal step distance so rows are harder to trigger than window steps

#### Scenario: Changing row-step distance changes row sensitivity
- **WHEN** the user increases the row-step distance
- **THEN** more vertical travel is required to switch Space-rows

#### Scenario: Reverse vertical persists
- **WHEN** the user toggles reverse-vertical and relaunches
- **THEN** the setting is retained and applied
