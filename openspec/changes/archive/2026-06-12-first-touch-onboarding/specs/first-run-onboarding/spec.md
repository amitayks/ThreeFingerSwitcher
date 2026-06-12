# first-run-onboarding — spec delta

## ADDED Requirements

### Requirement: First Touch wizard replaces the startup alert stack
On the first launch of a fresh install, the system SHALL present a dedicated, transient first-run wizard window — a sequence of full-bleed acts in the app's Liquid Glass material language (with the overlays' graceful fallback) — and SHALL NOT present any startup consent alerts (the legacy one-shot gesture/Spaces prompts) or open the Hub as the first-run surface. The wizard SHALL be the only surface that initiates permission requests and system-setting consent during first run.

#### Scenario: Fresh install shows the wizard, not alerts
- **WHEN** the app launches for the first time on a fresh install
- **THEN** the First Touch wizard window is shown
- **AND** no modal consent alerts are presented at startup

#### Scenario: Existing install never sees the wizard uninvited
- **WHEN** the app launches after upgrade on an install where any legacy first-run prompt flag is set or all required permissions are already granted
- **THEN** first-run onboarding is marked complete silently and the wizard does not appear

### Requirement: The demo plays before anything is asked
Before requesting any permission, the wizard SHALL present an interactive demo built from the product's own overlay presentation (the switcher strip rendered from sample data). The demo SHALL begin as a self-playing scripted scene, and WHEN live multitouch frames with three or more contacts are available it SHALL hand control to the user's actual fingers (tracking fingertips and scrubbing the strip from their motion). The demo act SHALL function fully when no live touch data is available.

#### Scenario: Demo runs with zero permissions
- **WHEN** the demo act is shown on a machine with no permissions granted
- **THEN** the simulated switcher strip animates from sample data without requesting anything

#### Scenario: Real fingers take over
- **WHEN** the user places three fingers on the trackpad during the demo act and touch frames are flowing
- **THEN** the scripted loop yields and the strip scrubs under the user's own finger motion

#### Scenario: No touch data degrades to cinema
- **WHEN** no multitouch frames are available (no trackpad, or the read is unavailable)
- **THEN** the demo continues as the scripted scene without error or a dead-end state

### Requirement: Permission steps are in-place upgrades with live status
The wizard SHALL request Accessibility and then Screen Recording, each step explaining what it unlocks before asking, deep-linking to the matching System Settings pane, and reflecting permission status live while visible (without requiring manual refresh). Upon each grant, the demo scene SHALL visibly upgrade in place: Accessibility transforms the sample cards into the user's real windows; Screen Recording (after the relaunch it requires) renders live thumbnails. The Screen Recording step SHALL offer an in-app relaunch action, and the wizard SHALL resume on that same step after the relaunch.

#### Scenario: Grant detected live
- **WHEN** the user grants a permission in System Settings while the wizard's permission act is visible
- **THEN** the wizard reflects the granted state within about a second, without a manual refresh action

#### Scenario: Accessibility makes the demo real
- **WHEN** Accessibility is granted during the wizard
- **THEN** the demo strip re-renders showing the user's actual windows in place of the sample cards

#### Scenario: Relaunch is offered and resumed
- **WHEN** the user grants Screen Recording and chooses the wizard's relaunch action
- **THEN** the app relaunches itself and the wizard reopens on the same step, now showing live window thumbnails in the demo

### Requirement: One consent moment for all system-setting changes
The wizard SHALL gather the user's gesture-feature choices (the core switcher, Space-row switching, the four-finger launcher, fixed Spaces order) on a single selection surface and SHALL present one explicit consent step that enumerates every system setting that will change, that prior values are backed up and restorable, and that one re-login is required for trackpad relocations to take effect. On consent it SHALL apply all chosen changes via the unified relocation apply (final values computed once, pristine backups first). Declining SHALL leave every system setting untouched while still allowing the wizard to complete.

#### Scenario: Combined choices, single consent, single apply
- **WHEN** the user selects Space-row switching and the launcher and consents
- **THEN** all required trackpad keys are written once with their final combined values, after pristine backups are taken
- **AND** only one re-login is required for everything chosen

#### Scenario: Declining changes nothing
- **WHEN** the user declines the consent step
- **THEN** no trackpad or Dock setting is modified and the wizard proceeds without them

### Requirement: One re-login moment, persisted and resumable
After applying trackpad relocations, the wizard SHALL present a single re-login step offering "Log out now" and "Later". The pending state SHALL be persisted so it survives app relaunches; choosing "Later" SHALL let the wizard complete with the affected features visibly marked pending, and the relocated features SHALL remain gated off until the relocation is actually effective. After a real re-login, the next launch SHALL acknowledge the change (the lanes are live) rather than silently proceeding.

#### Scenario: Later keeps an honest pending state
- **WHEN** the user chooses "Later" at the re-login step
- **THEN** the wizard completes with the relocation-bound features shown as pending re-login and those features stay gated off

#### Scenario: The re-login pays off
- **WHEN** the user logs out and back in after the wizard applied relocations
- **THEN** the next launch surfaces that the gestures are now live

### Requirement: Progress is persisted and every interruption resumes
The wizard SHALL persist its progress as a state machine across launches. Closing the window mid-flow SHALL be treated as "later", not abandonment: the next launch SHALL resume at the same act, and the Hub's Setup page SHALL offer a resume entry while onboarding is incomplete.

#### Scenario: Mid-flow quit resumes
- **WHEN** the user closes the wizard partway through and later relaunches the app
- **THEN** the wizard reopens at the act where they left off

#### Scenario: Resume from the Hub
- **WHEN** onboarding is incomplete and the user opens the Hub's Setup page
- **THEN** a resume entry for the welcome tour is offered

### Requirement: Completion is recorded once and replay is safe
On completion the system SHALL record a single first-run-completed flag and SHALL set the legacy one-shot prompt flags so the retired startup alerts can never fire. The wizard SHALL remain replayable from the Hub's Setup page; a replay SHALL render already-granted permissions and already-applied relocations in their done states and SHALL NOT re-write any setting without a fresh, explicit user action.

#### Scenario: Completion suppresses legacy prompts
- **WHEN** the wizard completes
- **THEN** the first-run-completed flag and all legacy prompt flags are set, and no legacy startup alert appears on subsequent launches

#### Scenario: Replay never silently re-applies
- **WHEN** the user replays the tour with permissions granted and relocations applied
- **THEN** those acts show their done states and no setting is written unless the user makes a new choice

### Requirement: Optional features are offered honestly and lazily
The wizard SHALL offer clipboard history, AI commands, and keyboard language as optional cards that state each feature's true cost plainly (clipboard records copied content locally; AI requires a one-time multi-gigabyte on-device model download and Apple Silicon; keyboard language needs no permission or re-login). Toggles SHALL write the same persisted preferences as the Hub pages. The wizard SHALL NOT request Calendar, Reminders, or Contacts permissions, SHALL NOT block on the AI model download, and SHALL treat skipping every optional feature as a first-class path to completion.

#### Scenario: Skipping everything completes cleanly
- **WHEN** the user declines all optional features
- **THEN** the wizard reaches completion with the core switcher configured and nothing else changed

#### Scenario: AI enablement does not block
- **WHEN** the user enables AI commands in the wizard
- **THEN** the model download proceeds in the background via the existing machinery and the wizard advances without waiting

### Requirement: The curtain offers permanence
The wizard's final act SHALL offer Open at Login (using the existing registration path, including its /Applications failure guidance), show where the app lives (the menu-bar mark) and where configuration lives (the Hub), and present a clear completion state.

#### Scenario: Open at Login from the wizard
- **WHEN** the user accepts the Open at Login offer
- **THEN** the app registers via the same mechanism as the Hub's General page, surfacing the same guidance on failure

### Requirement: The wizard degrades gracefully
WHEN a system-setting write is blocked (managed Mac), the wizard SHALL surface a calm, non-fatal explanation on the affected step and keep the feature gated off rather than assuming success. On a machine with no multitouch trackpad, the wizard SHALL still run (scripted demo, permissions, optional features) without error.

#### Scenario: Managed Mac degrades in place
- **WHEN** a trackpad write fails under management policy during the apply step
- **THEN** the wizard explains non-fatally that the change did not take effect and the affected feature stays off

#### Scenario: No trackpad still onboards
- **WHEN** the wizard runs on a Mac with no multitouch trackpad
- **THEN** all acts complete using the scripted demo and no error state appears
