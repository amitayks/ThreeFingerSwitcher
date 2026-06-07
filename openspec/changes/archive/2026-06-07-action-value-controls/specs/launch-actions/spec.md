## ADDED Requirements

### Requirement: Volume and brightness actions support an optional value control
The volume and brightness actions (`volumeUp`, `volumeDown`, `brightnessUp`, `brightnessDown`) SHALL support an optional per-item value control with two modes, performed natively and **without any new permission**:
- **Absolute** — set the level directly to a target percentage (e.g. volume = 30%).
- **Relative** — change the current level by a percentage-point amount; the action's direction selects the sign (Up adds, Down subtracts).

When no value control is set, the action SHALL retain its current behavior (synthesize the native media/brightness key, stepping by the OS increment). Levels SHALL be clamped to the valid 0–100% range. Volume SHALL be controlled via the system audio service and brightness via the display service; where a level cannot be read or set (e.g. some external displays), the system SHALL fall back to native key-stepping rather than failing or requesting a permission.

#### Scenario: Absolute sets the exact level
- **WHEN** a volume or brightness action with an absolute control of N% is fired
- **THEN** the corresponding level is set to N% (clamped to 0–100%), regardless of the action's up/down direction

#### Scenario: Relative changes by an amount
- **WHEN** a Volume Up (or Brightness Up) action with a relative control of N% is fired
- **THEN** the level increases by N percentage points from its current value (clamped); the Down variant decreases by N

#### Scenario: No control keeps native stepping
- **WHEN** a volume or brightness action with no value control is fired
- **THEN** it steps by the OS increment exactly as before

#### Scenario: Unsupported target falls back, never fails
- **WHEN** an absolute/relative control is fired but the level cannot be read or set (e.g. an external display without brightness control)
- **THEN** the system falls back to native key-stepping and does not crash or request a new permission

### Requirement: Value control is editable per item
The launcher editor SHALL let the user configure the value control on a volume or brightness action item: choosing Step (default), Set to a percentage, or Change by a percentage, and entering the percentage for the latter two. The setting SHALL persist with the item, and existing saved items (which predate the control) SHALL load unchanged with no control set.

#### Scenario: Configure a value action in the inspector
- **WHEN** the user selects a volume or brightness action item in the editor
- **THEN** the inspector offers Step / Set to % / Change by % and a percentage entry for the latter two, saved to the item

#### Scenario: Older favorites load without a control
- **WHEN** favorites saved before this feature are loaded
- **THEN** their action items decode successfully with no value control (native stepping), and favorites are not reset
