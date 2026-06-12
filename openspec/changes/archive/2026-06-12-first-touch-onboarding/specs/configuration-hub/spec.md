# configuration-hub — spec delta

## MODIFIED Requirements

### Requirement: Unified configuration Hub window
The system SHALL provide a single configuration **Hub** window that is the only surface for configuring every feature. Opening any configuration entry point (from the status menu or from in-app deep links) SHALL open this one window — there SHALL be no separate Settings, Favorites, Setup, or AI-command-editor window or sheet. The Hub SHALL be a single reusable window: re-opening it SHALL bring the existing window forward rather than creating another, and its frame SHALL persist across launches.

The one exception is the **First Touch wizard**: a transient first-run/replay window that is an onboarding performance, not a configuration surface. Every preference the wizard writes SHALL be the same persisted preference the Hub owns, and the wizard SHALL NOT host any configuration capability beyond its onboarding steps — the Hub remains the only place to configure the app.

#### Scenario: One window for all configuration
- **WHEN** the user opens configuration from the status menu
- **THEN** the Hub window opens, and no separate Settings, Favorites, Setup, or AI-command window exists

#### Scenario: Re-opening reuses the same window
- **WHEN** the Hub is already open and the user triggers it again
- **THEN** the existing Hub window is brought to the front (a second window is not created)

#### Scenario: Window frame persists
- **WHEN** the user resizes or moves the Hub and relaunches the app
- **THEN** the Hub reopens at its last position and size

#### Scenario: The wizard is not a configuration surface
- **WHEN** the First Touch wizard toggles a feature or opt-in
- **THEN** it writes the identical persisted preference as the corresponding Hub page, and any further configuration of that feature happens in the Hub

### Requirement: Setup page hosts permissions and native-gesture opt-ins
The Hub SHALL provide a **Setup** page that hosts the permissions status and guidance and the native-gesture opt-ins for ongoing (post-onboarding) use. The configuration entry point for permissions and setup SHALL be this page. The Setup page SHALL also offer the First Touch wizard entry: **Resume the welcome tour** while first-run onboarding is incomplete, and **Replay the welcome tour** after completion.

#### Scenario: Setup is the ongoing surface
- **WHEN** the user opens setup or permissions after onboarding is complete
- **THEN** the Hub's Setup page is shown

#### Scenario: Resume or replay the tour from Setup
- **WHEN** the user opens the Setup page
- **THEN** a resume entry is offered if onboarding is incomplete, or a replay entry if it is complete
