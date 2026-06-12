# spaces-rearrange-config — spec delta

## MODIFIED Requirements

### Requirement: Consent before changing the Spaces-rearrange setting
The system SHALL obtain explicit user consent before modifying the macOS "Automatically rearrange Spaces based on most recent use" setting and SHALL never change it silently. During first run, the consent surface SHALL be the First Touch wizard's feature-selection and consent step (where fixed Spaces order is offered alongside the gesture choices); thereafter, consent SHALL be gathered from the Hub.

#### Scenario: Consent gathered in the wizard on first run
- **WHEN** the first-run wizard's feature selection includes fixed Spaces order and the user consents
- **THEN** the change is applied; otherwise `mru-spaces` is not modified and the Dock is not restarted

#### Scenario: Declining leaves the setting untouched
- **WHEN** the user declines the consent step (or deselects fixed Spaces order)
- **THEN** `mru-spaces` is not modified and the Dock is not restarted

### Requirement: Persistent toggle and status surface
The system SHALL expose a persistent opt-in toggle in the Hub and SHALL reflect the current Spaces-rearrange state on the Hub's Setup page and in the first-run wizard's feature selection.

#### Scenario: Toggle controls management
- **WHEN** the user turns the Hub toggle off
- **THEN** the app restores the original value and stops managing the setting on future launches

#### Scenario: Status surfaces reflect state
- **WHEN** the Hub's Setup page or the wizard's feature-selection act is shown
- **THEN** it indicates whether Spaces auto-rearrange is currently on (with an action to turn it off) or off
