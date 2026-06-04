## ADDED Requirements

### Requirement: Raising under Stage Manager does not start a focus war
When Stage Manager is enabled, raising a current-Space window SHALL NOT assert per-application focus singletons (the window's `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`). The system SHALL instead raise the chosen window with `kAXRaiseAction` and activate its application, so that committing onto one of two windows of the same application that share the Stage Manager center stage does not start a self-sustaining focus oscillation between them. The focus-vacuum protections (activation fallback and the post-commit watchdog) SHALL remain in effect. When Stage Manager is disabled, the current-Space raise SHALL be unchanged.

#### Scenario: Co-staged same-app windows do not oscillate
- **WHEN** Stage Manager is enabled with app-window grouping and two windows of one application share the center stage, and the user commits to one of them
- **THEN** focus settles on a window of that application and does not oscillate between the two windows (no sustained window-order churn after the commit)

#### Scenario: Chosen window still becomes frontmost under Stage Manager
- **WHEN** a current-Space window is committed while Stage Manager is enabled
- **THEN** the window is raised with `kAXRaiseAction` and its application is activated so it becomes frontmost with keyboard focus, without writing `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`

#### Scenario: Behavior unchanged when Stage Manager is off
- **WHEN** Stage Manager is disabled and a current-Space window is committed
- **THEN** the full Accessibility sequence (`kAXRaiseAction` + `kAXMainAttribute` + the application's `kAXFocusedWindowAttribute`) plus activation runs exactly as before

#### Scenario: Off-Space raise unaffected by Stage Manager
- **WHEN** the committed window is on another Space (regardless of Stage Manager state)
- **THEN** the off-Space SkyLight front/key handshake plus the full Accessibility sequence runs unchanged

#### Scenario: Vacuum safety net retained under Stage Manager
- **WHEN** Stage Manager is enabled and a raise would otherwise leave the frontmost application with no key window
- **THEN** the activation fallback and the +180ms watchdog still establish a key window (no focus vacuum)
