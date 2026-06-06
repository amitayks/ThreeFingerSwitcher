# runtime-gesture-ownership Specification

## Purpose

Define how the app owns the freed three-finger vertical gesture at runtime when Space-row switching is effective. Freeing the OS three-finger vertical gesture turns it into a plain scroll, so the app consumes that scroll (it would otherwise leak to the background window) and synthesizes Mission Control / App Exposé itself (so idle three-finger up/down still works), using only the Accessibility permission it already holds — with no per-use re-login.

## Requirements

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

### Requirement: Scroll tap covers the launcher feature
The session scroll event tap SHALL run while the launcher opt-in is effective, in addition to when the Space-row opt-in is effective, so that the freed four-finger swipes — which macOS turns into plain scroll once their system assignment is removed — do not leak to the window under the cursor. The tap's consume rule SHALL consume scroll while **three or more fingers are in contact OR while the launcher overlay is open**. The launcher-open clause ensures that **two-finger movement during launcher navigation** is captured and does not scroll the window underneath. When the launcher overlay is **closed**, the consume rule reverts to three-or-more-contacts only, so normal two-finger scrolling passes through unchanged.

#### Scenario: Four-finger scroll is suppressed
- **WHEN** the launcher opt-in is effective and four fingers move (horizontally or vertically) over any window
- **THEN** the scroll is consumed and the background window does not scroll

#### Scenario: Tap runs for the launcher even if Space-row switching is off
- **WHEN** the launcher opt-in is effective and the Space-row opt-in is off
- **THEN** the scroll tap is running so four-finger scroll is suppressed

#### Scenario: Two-finger navigation is consumed while the launcher is open
- **WHEN** the launcher overlay is open and the user navigates with two fingers
- **THEN** the two-finger scroll is consumed and the window under the launcher does not scroll

#### Scenario: Two-finger scroll passes through when the launcher is closed
- **WHEN** the launcher overlay is not open and two fingers scroll
- **THEN** the scroll passes through and the window scrolls normally

#### Scenario: Tap stops when neither feature is effective
- **WHEN** neither the launcher opt-in nor the Space-row opt-in is effective (or the switcher is disabled)
- **THEN** the tap is stopped and the system handles scroll normally
