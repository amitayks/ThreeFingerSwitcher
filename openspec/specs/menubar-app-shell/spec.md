# menubar-app-shell Specification

## Purpose

Define the `LSUIElement` app lifecycle, the status-item menu, the sandbox-off packaging/distribution posture, and the app-wide wiring of the touch engine, gesture recognizer, window service, overlay, and settings.

## Requirements

### Requirement: Background menu-bar presence
The app SHALL run as a background agent (`LSUIElement = true`) with no Dock icon and no main window, presenting only a status-bar item.

#### Scenario: Launch shows no Dock icon
- **WHEN** the app launches
- **THEN** no Dock icon and no application window appear
- **AND** a status-bar item is shown in the menu bar

#### Scenario: Status menu actions
- **WHEN** the user clicks the status-bar item
- **THEN** a menu is shown offering at least: enable/disable the switcher, open Settings, and Quit

### Requirement: Status menu organization and diagnostics visibility
The status menu SHALL be organized into logical groups separated by dividers: a state group containing the switcher enable, the launcher enable/status, and Open at Login together; followed by contextual setup and launcher actions; followed by app entries (Settings and, when enabled, the diagnostic actions); ending with Quit. Setup & Permissions and restoring the native three-finger up/down (Mission Control) gesture SHALL be reachable from the Settings window rather than the status menu. The diagnostic actions (write diagnostics, copy focus log) SHALL appear in the status menu only when the show-diagnostics preference is enabled; otherwise they SHALL be hidden.

#### Scenario: Switcher, launcher, and Open at Login are grouped together
- **WHEN** the user opens the status menu
- **THEN** the switcher enable, the launcher enable/status, and Open at Login appear together in the same divider-separated group

#### Scenario: Diagnostics hidden by default
- **WHEN** the show-diagnostics preference is off (the default)
- **THEN** the status menu does not show the write-diagnostics or copy-focus-log entries

#### Scenario: Diagnostics shown when enabled
- **WHEN** the user enables the show-diagnostics preference in Settings
- **THEN** the write-diagnostics and copy-focus-log entries appear in the status menu

#### Scenario: Setup and Mission Control restore live in Settings
- **WHEN** the user opens the Settings window
- **THEN** it offers a Setup & Permissions entry, and — when a Mission Control backup exists — an entry to restore the native three-finger up/down gesture

### Requirement: Sandbox-off distribution posture
The app SHALL be built with App Sandbox disabled (required to load the private MultitouchSupport framework) and SHALL be distributable as a direct, notarized download rather than via the Mac App Store.

#### Scenario: Sandbox disabled in build
- **WHEN** the app's entitlements are inspected
- **THEN** App Sandbox is not enabled

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
The status menu SHALL offer an entry that opens the favorites editor, and an entry that adds the frontmost application to a chosen context band without opening the editor. The quick-add entry SHALL add the app to the favorites store and have it appear in the launcher on its next activation.

#### Scenario: Favorites entry opens the editor
- **WHEN** the user selects the favorites entry from the status menu
- **THEN** the favorites editor window opens

#### Scenario: Quick-add adds the front app
- **WHEN** the user chooses to add the frontmost app to a context band from the status menu
- **THEN** that app is added as an item to the chosen band and appears in the launcher on next activation
