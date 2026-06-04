## ADDED Requirements

### Requirement: Overlay panel does not perturb focus arbitration
The overlay panel SHALL use a window level and collection behavior that do not interfere with the WindowServer's focus/Space arbitration, and SHALL never be left ordered-in after a gesture ends.

#### Scenario: Non-interfering window configuration
- **WHEN** the overlay panel is created
- **THEN** it uses a transient window level (above normal windows and the menu bar, not the screen-saver band) and does not use an Exposé-exempt collection behavior

#### Scenario: Panel is always torn down
- **WHEN** a gesture ends by commit, cancel, the touch engine stopping, or the app resigning active
- **THEN** the overlay panel is ordered out (idempotently), never left visible

#### Scenario: Modal alerts are frontmost
- **WHEN** the app shows a modal alert
- **THEN** it activates first so the alert is key and frontmost rather than spinning a modal loop owned by a non-frontmost app
