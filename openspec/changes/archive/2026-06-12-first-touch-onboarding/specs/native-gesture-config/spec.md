# native-gesture-config — spec delta

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Consent before changing system settings
The system SHALL obtain explicit user consent before modifying any trackpad system setting and SHALL never change settings silently. During first run, the consent surface SHALL be the First Touch wizard's consent step; thereafter, consent SHALL be gathered from the Hub's Setup page or feature pages. Declining SHALL make no change.

#### Scenario: Consent gathered in the wizard on first run
- **WHEN** the first-run wizard reaches its consent step with gesture features selected
- **THEN** every system setting that will change is enumerated and nothing is written until the user consents
- **AND** it makes no change if consent is declined

#### Scenario: Consent gathered from the Hub thereafter
- **WHEN** the user enables a gesture opt-in from the Hub after onboarding
- **THEN** explicit consent is obtained before any trackpad setting is modified

### Requirement: Preserve and restore prior value
The system SHALL persist the prior value of any setting it changes — absent-aware, so a key that was previously unset is recorded as absent and deleted on restore rather than written — and SHALL offer to restore it on quit or uninstall.

#### Scenario: Restore on quit
- **WHEN** the user quits and the setting was changed by the app
- **THEN** the app offers to restore the original value

#### Scenario: Restore a previously-absent key
- **WHEN** the app restores the horizontal-gesture keys and a backed-up key was previously absent
- **THEN** it removes that key rather than writing an explicit value
