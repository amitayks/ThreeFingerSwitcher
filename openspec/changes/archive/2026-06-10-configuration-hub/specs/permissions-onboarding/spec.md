## MODIFIED Requirements

### Requirement: Guide the user to grant permissions
The system SHALL present permission guidance on the Hub's **Setup** page (not a separate Setup/Onboarding window) that explains each required permission and deep-links to the relevant System Settings pane, and reflects live permission status.

#### Scenario: Deep-link to settings
- **WHEN** the user chooses to grant a missing permission from the Hub's Setup page
- **THEN** the app opens the corresponding System Settings privacy pane

#### Scenario: Setup reflects live status
- **WHEN** a permission is granted while the Hub's Setup page is open
- **THEN** the Setup page updates to reflect the granted state
