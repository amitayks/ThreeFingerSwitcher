## MODIFIED Requirements

### Requirement: Status menu organization and diagnostics visibility
The status menu SHALL be trimmed to a minimal set of entries: **Open Hub**, a quick **enable/disable** toggle for the switcher, a quick **Add Front App to Band ▸** submenu, and **Quit** (plus the non-error "no trackpad detected" indication when applicable). All other configuration — tunables, Open at Login, launcher enable/status, Setup & Permissions, Mission Control restore, and native-gesture restore actions — SHALL live in the Hub rather than the status menu. The **diagnostic actions** (write diagnostics, copy focus log) SHALL appear in the status menu as their own group (before Quit) **only when the show-diagnostics preference is enabled**; when the preference is off (the default) they SHALL NOT appear anywhere — neither the status menu nor the Hub. The show-diagnostics preference itself SHALL be toggled on the Hub's General page (it governs the visibility of the menu actions; the Hub's General page SHALL NOT host the diagnostic action buttons).

#### Scenario: Menu is minimal and routes configuration to the Hub
- **WHEN** the user opens the status menu with the show-diagnostics preference off
- **THEN** it shows Open Hub, the switcher toggle, Add Front App to Band, and Quit, and does not show separate Settings/tunables, Open at Login, launcher status, setup, restore, or diagnostic entries

#### Scenario: Diagnostics hidden by default
- **WHEN** the show-diagnostics preference is off (the default)
- **THEN** the write-diagnostics and copy-focus-log actions are not shown anywhere (neither the status menu nor the Hub's General page)

#### Scenario: Diagnostics shown in the status menu when enabled
- **WHEN** the user enables the show-diagnostics preference (on the Hub's General page)
- **THEN** the write-diagnostics and copy-focus-log actions appear as a group in the status menu (and are NOT shown on the Hub's General page), and invoking them runs the same write-diagnostics / copy-focus-log actions as before

#### Scenario: Setup and Mission Control restore live in the Hub
- **WHEN** the user wants Setup & Permissions or — when a Mission Control backup exists — to restore the native three-finger up/down gesture
- **THEN** these are reached from the Hub, not the status menu
