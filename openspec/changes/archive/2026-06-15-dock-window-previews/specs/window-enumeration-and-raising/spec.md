## ADDED Requirements

### Requirement: App-scoped current-Space enumeration including minimized windows
The system SHALL provide an enumeration variant that returns the normal windows of a **single application** on the **current Space only**, and — unlike the switcher's all-Spaces enumeration — **including minimized windows**. Each returned window SHALL carry whether it is minimized so a consumer can badge it and choose the correct commit path. This variant SHALL NOT change the switcher's enumeration (all Spaces, minimized excluded); it is an additive mode. When Accessibility access is unavailable, the variant SHALL degrade without error and without introducing any new permission prompt.

#### Scenario: Returns only the requested app on the current Space
- **WHEN** the app-scoped current-Space variant is queried for application A
- **THEN** it returns A's normal windows on the current Space and no windows of other applications or other Spaces

#### Scenario: Includes minimized windows flagged as minimized
- **WHEN** application A has minimized windows on the current Space
- **THEN** those windows are included in the result and each is flagged as minimized

#### Scenario: Switcher enumeration is unchanged
- **WHEN** the switcher's enumeration runs
- **THEN** it still spans all Spaces and excludes minimized windows, unaffected by the new variant

#### Scenario: Degrades without Accessibility
- **WHEN** Accessibility access is not granted
- **THEN** the variant returns no error and prompts for no new permission

### Requirement: Un-minimize then raise on commit of a minimized window
When a commit targets a **minimized** window, the system SHALL un-minimize it (clearing the window's Accessibility minimized state) and then raise it using the existing raise path, so it becomes frontmost with keyboard focus. The existing raise hardening (activation fallback, post-commit watchdog, and the Stage-Manager hold-guard) SHALL remain in effect. A commit targeting a non-minimized window SHALL raise exactly as before.

#### Scenario: Minimized window is restored and raised
- **WHEN** a commit targets a minimized window
- **THEN** the window is un-minimized and then raised to the front with keyboard focus

#### Scenario: Non-minimized commit is unchanged
- **WHEN** a commit targets a non-minimized window
- **THEN** the existing raise sequence runs unchanged

#### Scenario: Raise hardening still applies after un-minimize
- **WHEN** a minimized window is un-minimized and raised
- **THEN** the activation fallback, post-commit watchdog, and Stage-Manager hold-guard still establish and hold keyboard focus
