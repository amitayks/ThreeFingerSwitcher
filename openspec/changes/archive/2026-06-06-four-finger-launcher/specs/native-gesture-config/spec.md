## ADDED Requirements

### Requirement: Free native four-finger swipe gestures
When the launcher opt-in is enabled (with consent), the system SHALL free the native four-finger horizontal and vertical swipe gestures by writing `TrackpadFourFingerHorizSwipeGesture` and `TrackpadFourFingerVertSwipeGesture` to disabled in both trackpad domains, backing up the prior values absent-aware first. The change SHALL be applied on launch while the opt-in is on, reapplied on relaunch, persisted across logout (not restored on quit), and restored to the exact prior values only on explicit opt-out — mirroring the three-finger vertical relocation. A one-time re-login SHALL be required for the change to take runtime effect, and the system SHALL detect-and-warn until effective. On managed (MDM) Macs that block the write, the system SHALL degrade non-fatally and leave the feature gated off.

#### Scenario: Enabling frees the four-finger swipes
- **WHEN** the user enables the launcher opt-in and grants consent
- **THEN** the four-finger horizontal and vertical swipe keys are backed up and set to disabled in both trackpad domains

#### Scenario: Disabling restores prior values
- **WHEN** the user disables the launcher opt-in
- **THEN** the four-finger swipe keys are restored to exactly their backed-up values (deleting keys that were originally absent)

#### Scenario: Re-login warning until effective
- **WHEN** the four-finger keys were changed this session but the change is not yet effective
- **THEN** the system warns that a re-login is needed and keeps the launcher gated off

#### Scenario: Managed Mac degrades non-fatally
- **WHEN** the trackpad write is blocked by management policy
- **THEN** the app surfaces a non-fatal warning and the launcher does not engage

### Requirement: Mission Control consolidates onto idle three-finger
Freeing four-finger vertical SHALL remove any four-finger Mission Control / App Exposé fallback. Mission Control (up) and App Exposé (down) SHALL remain available via the app's idle three-finger synthesis, so the user retains the gestures without an OS four-finger assignment.

#### Scenario: Four-finger MC fallback removed but MC still works
- **WHEN** the launcher opt-in frees four-finger vertical
- **THEN** four-finger vertical no longer opens Mission Control, but idle three-finger up/down still opens Mission Control / App Exposé via the app's synthesis

#### Scenario: Restoring re-enables the prior four-finger state
- **WHEN** the user disables the launcher opt-in
- **THEN** the four-finger vertical key is restored to its backed-up value (re-enabling a native four-finger Mission Control fallback if one was originally present)
