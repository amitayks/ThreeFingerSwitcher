## ADDED Requirements

### Requirement: Permission polling is scoped to a visible onboarding or Hub window
The periodic permission re-check (several cross-process TCC queries per tick) SHALL run only while a titled application window — the Hub or the first-run wizard — is actually visible. The presence of the menu-bar status item's own window, overlay panels, or a retained-but-hidden window SHALL NOT keep the poll running; an unbalanced start left behind by closing a retained window SHALL therefore go quiet on the next tick.

#### Scenario: Hub closed on the Setup page
- **WHEN** the user closes the Hub while its Setup page (which starts the poll) is showing
- **THEN** the poll performs no permission queries until a Hub or wizard window is visible again

#### Scenario: Status item alone does not count as a visible window
- **WHEN** only the menu-bar status item and the switcher/launcher overlays exist
- **THEN** the poll performs no permission queries
