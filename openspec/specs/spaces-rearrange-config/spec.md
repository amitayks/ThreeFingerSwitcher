# spaces-rearrange-config Specification

## Purpose
TBD - created by archiving change disable-spaces-auto-rearrange. Update Purpose after archive.
## Requirements
### Requirement: Consent before changing the Spaces-rearrange setting
The system SHALL obtain explicit user consent before modifying the macOS "Automatically rearrange Spaces based on most recent use" setting and SHALL never change it silently. During first run, the consent surface SHALL be the First Touch wizard's feature-selection and consent step (where fixed Spaces order is offered alongside the gesture choices); thereafter, consent SHALL be gathered from the Hub.

#### Scenario: Consent gathered in the wizard on first run
- **WHEN** the first-run wizard's feature selection includes fixed Spaces order and the user consents
- **THEN** the change is applied; otherwise `mru-spaces` is not modified and the Dock is not restarted

#### Scenario: Declining leaves the setting untouched
- **WHEN** the user declines the consent step (or deselects fixed Spaces order)
- **THEN** `mru-spaces` is not modified and the Dock is not restarted

### Requirement: Disable Spaces auto-rearrange with consent
With consent, the system SHALL set `com.apple.dock mru-spaces` to false and restart the Dock so the change takes effect, fixing the Mission Control Space order.

#### Scenario: Setting applied with consent
- **WHEN** the user consents and Spaces auto-rearrange is currently enabled
- **THEN** `mru-spaces` is set to false
- **AND** the Dock is restarted so Mission Control stops reordering Spaces by recent use

#### Scenario: No redundant Dock restart
- **WHEN** the setting is already false
- **THEN** the app does not rewrite the value or restart the Dock

### Requirement: Manage the setting across the app lifecycle
When the opt-in is enabled, the system SHALL apply the setting on launch, restore the original value on quit, and reapply it on relaunch, so the OS setting is changed only while the app is running.

#### Scenario: Apply on launch
- **WHEN** the app launches with the opt-in enabled and the setting is not already false
- **THEN** it backs up the current state, sets `mru-spaces` to false, and restarts the Dock

#### Scenario: Restore on quit
- **WHEN** the app quits and it changed the setting during this session
- **THEN** it restores the original value before exiting

#### Scenario: Reapply on relaunch
- **WHEN** the app is launched again with the opt-in still enabled
- **THEN** it applies the setting again

### Requirement: Preserve and restore the exact prior state
The system SHALL persist the prior state of `mru-spaces` — including the common case where the key is absent (the default) — and SHALL restore the system to exactly that state.

#### Scenario: Restore a previously-absent key
- **WHEN** the app restores and the backed-up prior state was "absent"
- **THEN** it removes the `mru-spaces` key rather than writing an explicit value
- **AND** the Dock is restarted so the original behavior resumes

#### Scenario: Restore a previously-explicit value
- **WHEN** the app restores and the backed-up prior state was an explicit true or false
- **THEN** it writes that value back

### Requirement: Persistent toggle and status surface
The system SHALL expose a persistent opt-in toggle in the Hub and SHALL reflect the current Spaces-rearrange state on the Hub's Setup page and in the first-run wizard's feature selection.

#### Scenario: Toggle controls management
- **WHEN** the user turns the Hub toggle off
- **THEN** the app restores the original value and stops managing the setting on future launches

#### Scenario: Status surfaces reflect state
- **WHEN** the Hub's Setup page or the wizard's feature-selection act is shown
- **THEN** it indicates whether Spaces auto-rearrange is currently on (with an action to turn it off) or off

### Requirement: Surface failures instead of assuming success
The system SHALL detect when writing the setting or restarting the Dock does not succeed (for example, a managed preference) and SHALL surface a non-fatal warning rather than assume the change took effect.

#### Scenario: Write or restart fails
- **WHEN** the app cannot write `mru-spaces` or restart the Dock
- **THEN** it surfaces a warning explaining that the change may not have taken effect
- **AND** it does not crash or block normal switcher operation

