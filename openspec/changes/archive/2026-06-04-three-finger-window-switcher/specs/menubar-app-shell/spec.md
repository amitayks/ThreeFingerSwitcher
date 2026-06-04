## ADDED Requirements

### Requirement: Background menu-bar presence
The app SHALL run as a background agent (`LSUIElement = true`) with no Dock icon and no main window, presenting only a status-bar item.

#### Scenario: Launch shows no Dock icon
- **WHEN** the app launches
- **THEN** no Dock icon and no application window appear
- **AND** a status-bar item is shown in the menu bar

#### Scenario: Status menu actions
- **WHEN** the user clicks the status-bar item
- **THEN** a menu is shown offering at least: enable/disable the switcher, open Settings, open Permissions/Onboarding, and Quit

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
