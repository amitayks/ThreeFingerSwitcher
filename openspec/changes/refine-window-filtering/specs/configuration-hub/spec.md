# configuration-hub — delta for refine-window-filtering

## ADDED Requirements

### Requirement: Window Inspector on the Switcher page

The Switcher page SHALL host a Window Inspector: an on-demand snapshot of every regular application's current-Space window candidates, grouped by application, showing each window's title, size, subrole, and its filter verdict — Listed, a typed drop reason, or deduplicated — computed by the same filter that drives the switcher, so the inspector and the switcher can never disagree. Each application group SHALL offer an inline rule picker (follow global / include / strict / exclude) writing the persisted per-app rules, so a wrong verdict is correctable in place.

The inspector SHALL refresh only on explicit user action (a refresh control) plus one load when it first appears; it SHALL NOT poll, tick, or auto-refresh on a timer (the hidden-window idle-CPU landmine). The list SHALL be bounded and scroll-safe within the page.

#### Scenario: Verdicts are visible per window

- **WHEN** the user opens the inspector while a window is being filtered out
- **THEN** the window appears in its app's group with its drop reason (or "duplicate") rather than being silently absent

#### Scenario: Per-app rule is editable in place

- **WHEN** the user changes an app's rule in the inspector
- **THEN** the persisted per-app rule updates and the next snapshot reflects the new verdicts

#### Scenario: No background refresh

- **WHEN** the inspector is visible but the user takes no action
- **THEN** no periodic re-enumeration occurs; the snapshot updates only via the refresh control or re-appearance
