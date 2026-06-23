# menubar-app-shell Specification

## Purpose

Define the `LSUIElement` app lifecycle, the status-item menu, the sandbox-off packaging/distribution posture, and the app-wide wiring of the touch engine, gesture recognizer, window service, overlay, and settings.
## Requirements
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

### Requirement: Sandbox-off distribution posture
The app SHALL be built with App Sandbox disabled (required to load the private MultitouchSupport framework) and SHALL be distributable as a direct, notarized download rather than via the Mac App Store. This posture SHALL be **realized** by a Developer-ID-signed, notarized, stapled DMG published to GitHub Releases (see the `release-pipeline` capability).

#### Scenario: Sandbox disabled in build
- **WHEN** the app's entitlements are inspected
- **THEN** App Sandbox is not enabled

#### Scenario: Distribution is a notarized direct download
- **WHEN** a published release artifact is examined
- **THEN** it is a Developer-ID-signed, notarized, stapled DMG offered as a direct download (not a Mac App Store listing)

### Requirement: Engine lifecycle wiring
The app SHALL own and wire together the touch engine, gesture recognizer, window service, overlay, and settings, starting touch listening when enabled and stopping it when disabled or quitting.

#### Scenario: Enable starts listening
- **WHEN** the switcher is enabled
- **THEN** the app begins listening to the touch stream and the gesture recognizer is active

#### Scenario: Disable stops listening
- **WHEN** the switcher is disabled
- **THEN** the app stops listening to the touch stream and no overlay can appear

#### Scenario: Graceful quit
- **WHEN** the user quits the app
- **THEN** touch listening stops and any pending native-gesture-setting restore offer is honored per the native-gesture-config capability

### Requirement: Inert when no trackpad is available
The app SHALL remain stable and surface a clear non-error state when no multitouch trackpad is present.

#### Scenario: No trackpad device
- **WHEN** the app runs on a Mac with no multitouch trackpad
- **THEN** the app does not crash
- **AND** the status menu indicates the switcher is unavailable because no trackpad was detected

### Requirement: Favorites editor and quick-add entry points
The status menu SHALL offer an entry that opens the Hub (whose Bands page edits the context bands and their items), and an entry that adds the frontmost application to a chosen context band without opening the Hub. The quick-add entry SHALL add the app to the favorites store and have it appear in the launcher on its next activation.

#### Scenario: Hub entry reaches the bands editor
- **WHEN** the user selects Open Hub from the status menu
- **THEN** the Hub opens and its Bands page edits the context bands and their items

#### Scenario: Quick-add adds the front app
- **WHEN** the user chooses to add the frontmost app to a context band from the status menu
- **THEN** that app is added as an item to the chosen band and appears in the launcher on next activation

