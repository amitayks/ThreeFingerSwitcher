# native-gesture-config Specification

## Purpose

Define config-based detection, disabling, and restoration of the "Swipe between full-screen applications" trackpad setting with explicit user consent, so the horizontal three-finger gesture is unclaimed by the OS while Mission Control and App Exposé remain intact.

## Requirements

### Requirement: Consent before changing system settings
The system SHALL obtain explicit user consent before modifying any trackpad system setting and SHALL never change settings silently.

#### Scenario: Consent prompt on first run
- **WHEN** the app first determines that "Swipe between full-screen applications" is enabled
- **THEN** it prompts the user for consent before changing it
- **AND** it makes no change if consent is declined

### Requirement: Disable native horizontal full-screen swipe
With consent, the system SHALL turn off the "Swipe between full-screen applications" trackpad setting so the horizontal three-finger gesture is unclaimed by the OS. The native three-finger vertical gestures (Mission Control / App Exposé) SHALL be left intact on three fingers UNLESS the user separately opts into Space-row switching, which relocates them to four fingers.

#### Scenario: Setting turned off with consent
- **WHEN** the user consents
- **THEN** the "Swipe between full-screen applications" setting is turned off
- **AND** Mission Control and App Exposé remain available on three-finger up/down while the Space-row switching opt-in is off

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

### Requirement: Consent before changing the native vertical gesture
The system SHALL obtain explicit user consent before relocating the native three-finger vertical gesture (Mission Control / App Exposé) and SHALL never change it silently. Enabling Space-row switching is the consent action; declining SHALL leave the gesture untouched.

#### Scenario: Consent prompt on first run
- **WHEN** the app first determines that the native three-finger vertical gesture is on three fingers and the user has not yet been asked
- **THEN** it prompts the user, explaining that enabling Space-row switching moves Mission Control / App Exposé to four fingers
- **AND** it makes no change if consent is declined

#### Scenario: Declining leaves the gesture untouched
- **WHEN** the user declines the prompt or leaves the opt-in off
- **THEN** the vertical trackpad keys are not modified and Mission Control / App Exposé stay on three fingers

### Requirement: Relocate the native vertical gesture to four fingers with consent
With consent, the system SHALL reassign the native three-finger vertical gesture (Mission Control / App Exposé) to four fingers across both trackpad domains, so the three-finger vertical swipe is unclaimed by the OS and free for Space-row switching.

#### Scenario: Gesture relocated with consent
- **WHEN** the user enables Space-row switching and the native vertical gesture is currently on three fingers
- **THEN** the three-finger vertical trackpad setting is turned off and the four-finger vertical setting is turned on
- **AND** Mission Control / App Exposé are available on four-finger up/down

#### Scenario: No redundant write when already relocated
- **WHEN** the native three-finger vertical gesture is already off
- **THEN** the app does not rewrite the values

### Requirement: Manage the native vertical gesture across the app lifecycle
When Space-row switching is enabled, the system SHALL apply the gesture relocation on launch and reapply on relaunch, and SHALL keep it applied (persisted) while the opt-in is on — including across logout/restart — so the re-login that makes the change effective is not undone. The relocation SHALL be reverted only when the user disables the opt-in or explicitly chooses to restore, never automatically on quit.

#### Scenario: Apply on launch
- **WHEN** the app launches with Space-row switching enabled and the native vertical gesture is not already relocated
- **THEN** it backs up the current values and relocates the three-finger vertical gesture to four fingers

#### Scenario: Relocation persists across quit and logout
- **WHEN** the app quits (including the logout/restart needed to make the change effective) while Space-row switching is still on
- **THEN** the relocated value is left in place (not reverted), so the next login frees the three-finger vertical swipe

#### Scenario: Reapply on relaunch is a no-op when already relocated
- **WHEN** the app is launched again with Space-row switching still enabled and the value already reads relocated
- **THEN** it makes no further write, so the change is not re-marked as "this session" and becomes effective

#### Scenario: Restore on disabling the opt-in
- **WHEN** the user turns Space-row switching off (or chooses Restore from the menu)
- **THEN** the app restores the original vertical trackpad values

### Requirement: Preserve and restore the exact prior vertical-gesture values
The system SHALL persist the prior values of every vertical trackpad key it changes (including absent keys) and SHALL restore the system to exactly that state, deleting keys that were previously absent rather than writing an explicit value.

#### Scenario: Restore previously-absent keys
- **WHEN** the app restores and a backed-up key was previously absent
- **THEN** it removes that key rather than writing an explicit value

#### Scenario: Restore previously-set values
- **WHEN** the app restores and a backed-up key had an explicit prior value
- **THEN** it writes back exactly that value

### Requirement: Detect and warn on effective vertical-gesture state
The system SHALL detect whether the native vertical gesture relocation is effectively active and, when it is not yet effective at runtime (e.g. a re-login is required), SHALL warn the user rather than assume the change took effect, and SHALL NOT enable vertical row stepping until the relocation is effective.

#### Scenario: Warn when still active
- **WHEN** the vertical-gesture relocation has not yet taken effect at runtime
- **THEN** the app surfaces a warning explaining that a re-login may be required
- **AND** vertical row stepping does not engage until the relocation is effective

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
