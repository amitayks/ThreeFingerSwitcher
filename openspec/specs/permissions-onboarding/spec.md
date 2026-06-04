# permissions-onboarding Specification

## Purpose

Define detection of and guidance for granting the Accessibility, Screen Recording, and (if needed) Input Monitoring permissions, including deep-links to System Settings and graceful degradation when permissions are missing.

## Requirements

### Requirement: Detect required permissions
The system SHALL detect whether Accessibility and Screen Recording permissions are granted, and SHALL detect Input Monitoring status if the multitouch read requires it.

#### Scenario: Missing Accessibility detected
- **WHEN** Accessibility permission is not granted
- **THEN** the app reports Accessibility as missing in onboarding

#### Scenario: Missing Screen Recording detected
- **WHEN** Screen Recording permission is not granted
- **THEN** the app reports Screen Recording as missing in onboarding

### Requirement: Guide the user to grant permissions
The system SHALL present an onboarding UI that explains each required permission and deep-links to the relevant System Settings pane.

#### Scenario: Deep-link to settings
- **WHEN** the user chooses to grant a missing permission
- **THEN** the app opens the corresponding System Settings privacy pane

#### Scenario: Onboarding reflects live status
- **WHEN** a permission is granted while onboarding is open
- **THEN** the onboarding UI updates to reflect the granted state

### Requirement: Degrade gracefully when permissions are missing
The system SHALL behave safely when permissions are missing: without Accessibility it SHALL not attempt to raise windows; without Screen Recording it SHALL fall back to icon/title-only cards.

#### Scenario: No Accessibility disables raising
- **WHEN** Accessibility is not granted
- **THEN** the switcher does not attempt to raise windows and prompts the user to grant access

#### Scenario: No Screen Recording falls back to icons
- **WHEN** Screen Recording is not granted
- **THEN** the overlay shows app icon + title cards without thumbnails
