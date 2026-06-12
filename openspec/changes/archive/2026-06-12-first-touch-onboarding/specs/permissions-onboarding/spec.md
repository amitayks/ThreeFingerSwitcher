# permissions-onboarding — spec delta

## MODIFIED Requirements

### Requirement: Guide the user to grant permissions
The system SHALL present first-run permission guidance in the First Touch wizard and ongoing permission guidance on the Hub's **Setup** page. Both surfaces SHALL explain each required permission and what it unlocks, deep-link to the relevant System Settings pane, and reflect permission status live while visible — updating within about a second of a grant without requiring a manual refresh. The Screen Recording guidance SHALL state that the grant takes effect only after the app relaunches and SHALL offer an in-app relaunch action that performs the quit-and-reopen.

#### Scenario: Deep-link to settings
- **WHEN** the user chooses to grant a missing permission from the wizard or the Hub's Setup page
- **THEN** the app opens the corresponding System Settings privacy pane

#### Scenario: Status reflects live while visible
- **WHEN** a permission is granted in System Settings while the wizard's permission act or the Hub's Setup page is open
- **THEN** the surface updates to the granted state within about a second, without a manual refresh action

#### Scenario: Screen Recording relaunch is handled in-app
- **WHEN** the user grants Screen Recording and invokes the relaunch action
- **THEN** the app quits and reopens itself, and thumbnails work in the new process

## ADDED Requirements

### Requirement: First contact is owned by onboarding
While first-run onboarding is incomplete, a committed switch with Accessibility missing SHALL NOT trigger the OS Accessibility prompt mid-gesture — the commit is simply inert. The wizard SHALL be the only surface that initiates the Accessibility request during first run. After onboarding completes, the mid-gesture prompt path MAY serve as a safety net for the granted-then-revoked case.

#### Scenario: No mid-gesture prompt during first run
- **WHEN** onboarding is incomplete, Accessibility is missing, and the user commits a switch
- **THEN** no OS permission prompt appears mid-gesture and the commit is a no-op

#### Scenario: Safety net after onboarding
- **WHEN** onboarding is complete and Accessibility has been revoked since
- **THEN** a committed switch may surface the Accessibility request as before
