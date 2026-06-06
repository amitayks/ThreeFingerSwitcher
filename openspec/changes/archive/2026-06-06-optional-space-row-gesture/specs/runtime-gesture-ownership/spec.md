## ADDED Requirements

### Requirement: Consume the freed three-finger scroll at runtime
When the Space-row switching opt-in is effective, the system SHALL run a session scroll event tap that consumes scroll-wheel events while three or more fingers are in contact, so the freed three-finger vertical gesture (which macOS turns into a plain scroll once its system assignment is removed) does not leak to the window under the cursor. Two-finger scrolling SHALL pass through untouched. The tap SHALL require only the Accessibility permission the app already holds for window raising (Input Monitoring SHALL NOT be required).

#### Scenario: Three-finger scroll is suppressed
- **WHEN** the feature is effective and three fingers move vertically (over any window)
- **THEN** the scroll is consumed and the background window does not scroll

#### Scenario: Two-finger scroll is unaffected
- **WHEN** two fingers scroll
- **THEN** the scroll passes through and the window scrolls normally

#### Scenario: Tap runs only while the feature is live
- **WHEN** the opt-in is effective and the switcher is enabled
- **THEN** the tap is running; and **WHEN** the switcher is disabled or the opt-in is off or not yet effective
- **THEN** the tap is stopped (the system handles scroll normally)

### Requirement: Synthesize Mission Control / App Exposé for idle vertical swipes
When the Space-row switching opt-in is effective, the system SHALL open Mission Control (three-finger up) or App Exposé (three-finger down) itself in response to the recognizer's fresh-vertical intent, so idle three-finger up/down keeps working even though the OS gesture is freed. The trigger SHALL use a private system call resolved crash-safely (a missing symbol degrades to a no-op, never a crash).

#### Scenario: Idle three-finger up opens Mission Control
- **WHEN** the feature is effective and a fresh three-finger up swipe is recognized
- **THEN** Mission Control opens

#### Scenario: Idle three-finger down opens App Exposé
- **WHEN** the feature is effective and a fresh three-finger down swipe is recognized
- **THEN** App Exposé opens

#### Scenario: Native handling when the feature is off
- **WHEN** the opt-in is off (the OS still owns the three-finger vertical gesture)
- **THEN** the app does not synthesize the overview; macOS opens Mission Control / App Exposé natively

### Requirement: Idle Mission Control survives across logins without per-use re-login
The one-time logout/login that frees the OS gesture SHALL be the only re-login required; thereafter the runtime tap and the synthesized Mission Control / App Exposé SHALL provide idle three-finger up/down and suppress the background scroll with no further re-login, for as long as the opt-in stays on.

#### Scenario: Works immediately after the one-time re-login
- **WHEN** the user has enabled the opt-in and logged back in once
- **THEN** idle three-finger up/down opens the overview and overlay row-switching does not scroll the background, on every subsequent launch, with no additional re-login
