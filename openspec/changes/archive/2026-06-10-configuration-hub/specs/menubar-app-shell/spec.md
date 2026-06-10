## MODIFIED Requirements

### Requirement: Background menu-bar presence
The app SHALL run as a background agent (`LSUIElement = true`) with no Dock icon and no main window, presenting only a status-bar item. The status-bar item SHALL display the app's **brand mark** (a template image derived from the project logo) rather than a generic system symbol.

#### Scenario: Launch shows no Dock icon
- **WHEN** the app launches
- **THEN** no Dock icon and no application window appear
- **AND** a status-bar item is shown in the menu bar

#### Scenario: Status item shows the brand mark
- **WHEN** the status-bar item is shown
- **THEN** it displays the app's brand mark as a template image (auto-adapting to light/dark menu bar), not a stock SF Symbol

#### Scenario: Status menu actions
- **WHEN** the user clicks the status-bar item
- **THEN** a menu is shown offering at least: open the Hub, enable/disable the switcher, add the front app to a band, and Quit

### Requirement: Status menu organization and diagnostics visibility
The status menu SHALL be trimmed to a minimal set of entries: **Open Hub**, a quick **enable/disable** toggle for the switcher, a quick **Add Front App to Band ▸** submenu, and **Quit** (plus the non-error "no trackpad detected" indication when applicable). All other configuration — tunables, Open at Login, launcher enable/status, Setup & Permissions, Mission Control restore, native-gesture restore actions, and the diagnostic actions (write diagnostics, copy focus log) — SHALL live in the Hub rather than the status menu. The diagnostic actions SHALL be available on the Hub's General page only when the show-diagnostics preference is enabled; otherwise they SHALL be hidden.

#### Scenario: Menu is minimal and routes configuration to the Hub
- **WHEN** the user opens the status menu
- **THEN** it shows Open Hub, the switcher toggle, Add Front App to Band, and Quit, and does not show separate Settings/tunables, Open at Login, launcher status, setup, or restore entries

#### Scenario: Diagnostics hidden by default
- **WHEN** the show-diagnostics preference is off (the default)
- **THEN** the write-diagnostics and copy-focus-log actions are not shown anywhere (neither the menu nor the Hub)

#### Scenario: Diagnostics shown in the Hub when enabled
- **WHEN** the user enables the show-diagnostics preference
- **THEN** the write-diagnostics and copy-focus-log actions appear on the Hub's General page (not in the status menu)

#### Scenario: Setup and Mission Control restore live in the Hub
- **WHEN** the user wants Setup & Permissions or — when a Mission Control backup exists — to restore the native three-finger up/down gesture
- **THEN** these are reached from the Hub, not the status menu

### Requirement: Favorites editor and quick-add entry points
The status menu SHALL offer an entry that opens the Hub (whose Bands page edits the context bands and their items), and an entry that adds the frontmost application to a chosen context band without opening the Hub. The quick-add entry SHALL add the app to the favorites store and have it appear in the launcher on its next activation.

#### Scenario: Hub entry reaches the bands editor
- **WHEN** the user selects Open Hub from the status menu
- **THEN** the Hub opens and its Bands page edits the context bands and their items

#### Scenario: Quick-add adds the front app
- **WHEN** the user chooses to add the frontmost app to a context band from the status menu
- **THEN** that app is added as an item to the chosen band and appears in the launcher on next activation
