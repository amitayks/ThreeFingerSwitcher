# native-gesture-config Specification

## Purpose

Define config-based detection, disabling, and restoration of the "Swipe between full-screen applications" trackpad setting with explicit user consent, so the horizontal three-finger gesture is unclaimed by the OS while Mission Control and App Exposé remain intact.

## Requirements

### Requirement: Consent before changing system settings
The system SHALL obtain explicit user consent before modifying any trackpad system setting and SHALL never change settings silently. During first run, the consent surface SHALL be the First Touch wizard's consent step; thereafter, consent SHALL be gathered from the Hub's Setup page or feature pages. Declining SHALL make no change.

#### Scenario: Consent gathered in the wizard on first run
- **WHEN** the first-run wizard reaches its consent step with gesture features selected
- **THEN** every system setting that will change is enumerated and nothing is written until the user consents
- **AND** it makes no change if consent is declined

#### Scenario: Consent gathered from the Hub thereafter
- **WHEN** the user enables a gesture opt-in from the Hub after onboarding
- **THEN** explicit consent is obtained before any trackpad setting is modified

### Requirement: Unified multi-relocation apply
WHEN the user consents to multiple gesture-feature choices together (e.g. in the first-run wizard), the system SHALL compile them into a single relocation plan: the final value of every affected trackpad key SHALL be computed once from the full set of chosen features, pristine prior values of every key the plan touches SHALL be snapshotted absent-aware into the per-feature backup slots **before any write**, and the final values SHALL then be written once to both trackpad domains. A single re-login SHALL make all chosen relocations effective. The plan SHALL resolve the shared four-finger keys from the combination (launcher chosen ⇒ four-finger swipes freed; otherwise the horizontal relocation's four-finger fallback and/or the vertical relocation's four-finger Mission Control apply).

#### Scenario: Combined apply writes final values once
- **WHEN** the user consents to Space-row switching and the launcher together
- **THEN** the three-finger horizontal and vertical keys are freed and both four-finger keys are freed, written once with no intermediate values
- **AND** one re-login makes everything chosen effective

#### Scenario: Backups stay pristine under combination
- **WHEN** a combined apply touches a key that two features share
- **THEN** every per-feature backup slot holds the pre-plan (pristine) value, not an intermediate value written by another feature's relocation

#### Scenario: Individual restore after a combined apply
- **WHEN** the user later restores a single feature's relocation from the Setup page
- **THEN** that feature's keys return to their pristine pre-plan values (deleting keys that were originally absent)

### Requirement: Pending re-login state survives app relaunch
The system SHALL persist a pending-re-login marker when it writes a trackpad relocation, recording the current login-session identity. The marker SHALL remain pending across app relaunches within the same login session and SHALL be cleared only when the app launches in a different login session (a real re-login). Feature effectiveness gates and all "needs re-login" status surfaces SHALL read this persisted marker rather than an in-memory session flag.

#### Scenario: App relaunch does not fake effectiveness
- **WHEN** the app is quit and relaunched without logging out after a relocation was written
- **THEN** the relocation still reads as pending re-login and the bound feature stays gated off

#### Scenario: A real re-login clears the marker
- **WHEN** the user logs out and back in after a relocation was written
- **THEN** the next launch detects the new login session, clears the pending marker, and the bound feature engages

### Requirement: Disable native horizontal full-screen swipe
With consent, the system SHALL turn off the "Swipe between full-screen applications" trackpad setting so the horizontal three-finger gesture is unclaimed by the OS. The native three-finger vertical gestures (Mission Control / App Exposé) SHALL be left intact on three fingers UNLESS the user separately opts into Space-row switching, which relocates them to four fingers.

#### Scenario: Setting turned off with consent
- **WHEN** the user consents
- **THEN** the "Swipe between full-screen applications" setting is turned off
- **AND** Mission Control and App Exposé remain available on three-finger up/down while the Space-row switching opt-in is off

### Requirement: Preserve and restore prior value
The system SHALL persist the prior value of any setting it changes — absent-aware, so a key that was previously unset is recorded as absent and deleted on restore rather than written — and SHALL offer to restore it on quit or uninstall.

#### Scenario: Restore on quit
- **WHEN** the user quits and the setting was changed by the app
- **THEN** the app offers to restore the original value

#### Scenario: Restore a previously-absent key
- **WHEN** the app restores the horizontal-gesture keys and a backed-up key was previously absent
- **THEN** it removes that key rather than writing an explicit value

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
