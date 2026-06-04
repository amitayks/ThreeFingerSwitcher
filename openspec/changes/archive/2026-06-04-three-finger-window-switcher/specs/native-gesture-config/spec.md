## ADDED Requirements

### Requirement: Consent before changing system settings
The system SHALL obtain explicit user consent before modifying any trackpad system setting and SHALL never change settings silently.

#### Scenario: Consent prompt on first run
- **WHEN** the app first determines that "Swipe between full-screen applications" is enabled
- **THEN** it prompts the user for consent before changing it
- **AND** it makes no change if consent is declined

### Requirement: Disable native horizontal full-screen swipe
With consent, the system SHALL turn off the "Swipe between full-screen applications" trackpad setting so the horizontal three-finger gesture is unclaimed by the OS, while leaving Mission Control and App Exposé on three fingers.

#### Scenario: Setting turned off with consent
- **WHEN** the user consents
- **THEN** the "Swipe between full-screen applications" setting is turned off
- **AND** Mission Control and App Exposé remain available on three-finger up/down

### Requirement: Preserve and restore prior value
The system SHALL persist the prior value of any setting it changes and SHALL offer to restore it on quit or uninstall.

#### Scenario: Restore on quit
- **WHEN** the user quits and the setting was changed by the app
- **THEN** the app offers to restore the original value

### Requirement: Detect and warn on effective state
The system SHALL detect whether the horizontal full-screen swipe is still effectively active and SHALL warn the user (e.g., that a re-login may be required) rather than assume the change took effect.

#### Scenario: Warn when still active
- **WHEN** the setting change has not yet taken effect at runtime
- **THEN** the app surfaces a warning explaining that the native gesture is still active and how to resolve it
