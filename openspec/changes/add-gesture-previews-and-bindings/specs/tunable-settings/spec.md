## ADDED Requirements

### Requirement: Persisted gesture-binding settings
The app SHALL persist the user's **gesture bindings** (`gesture-bindings`) for the remappable surfaces — the AI canvas resolve mapping, the Files-drill resolution mapping, and the switcher per-axis scrub directions — alongside the other tunables, using the same persistence and reset semantics. Each binding SHALL **default to today's behavior** (canvas down = commit / horizontal = dismiss / up = ignore; Files lift = open / +1-finger = Open-With / four-finger horizontal = discard; both switcher axes normal). The prior standalone **reverse-direction** preferences SHALL be **folded into** the switcher-axis bindings as the single source of truth (no duplicate persisted keys). Resetting settings to defaults SHALL restore every binding to its default.

#### Scenario: Bindings persist across launches
- **WHEN** the user changes a gesture binding and relaunches the app
- **THEN** the changed binding is restored from persistence

#### Scenario: Defaults reproduce prior behavior
- **WHEN** a user upgrades and has never set a binding
- **THEN** every surface behaves exactly as before (including the prior reverse-direction settings, now expressed as switcher-axis bindings)

#### Scenario: Reset restores default bindings
- **WHEN** the user resets settings to defaults
- **THEN** all gesture bindings return to their defaults

#### Scenario: Reverse-direction has a single source of truth
- **WHEN** the user sets a switcher axis to reversed
- **THEN** that state is the switcher-axis binding (there is no separate reverse-direction key that can diverge)
