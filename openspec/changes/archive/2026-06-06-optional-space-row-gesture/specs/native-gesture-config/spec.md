## MODIFIED Requirements

### Requirement: Disable native horizontal full-screen swipe
With consent, the system SHALL turn off the "Swipe between full-screen applications" trackpad setting so the horizontal three-finger gesture is unclaimed by the OS. The native three-finger vertical gestures (Mission Control / App Exposé) SHALL be left intact on three fingers UNLESS the user separately opts into Space-row switching, which relocates them to four fingers.

#### Scenario: Setting turned off with consent
- **WHEN** the user consents
- **THEN** the "Swipe between full-screen applications" setting is turned off
- **AND** Mission Control and App Exposé remain available on three-finger up/down while the Space-row switching opt-in is off

## ADDED Requirements

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
