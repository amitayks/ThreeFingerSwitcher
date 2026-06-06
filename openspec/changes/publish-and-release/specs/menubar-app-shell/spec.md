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
- **THEN** a menu is shown offering at least: enable/disable the switcher, open Settings, open Permissions/Onboarding, and Quit

### Requirement: Sandbox-off distribution posture
The app SHALL be built with App Sandbox disabled (required to load the private MultitouchSupport framework) and SHALL be distributable as a direct, notarized download rather than via the Mac App Store. This posture SHALL be **realized** by a Developer-ID-signed, notarized, stapled DMG published to GitHub Releases (see the `release-pipeline` capability).

#### Scenario: Sandbox disabled in build
- **WHEN** the app's entitlements are inspected
- **THEN** App Sandbox is not enabled

#### Scenario: Distribution is a notarized direct download
- **WHEN** a published release artifact is examined
- **THEN** it is a Developer-ID-signed, notarized, stapled DMG offered as a direct download (not a Mac App Store listing)
