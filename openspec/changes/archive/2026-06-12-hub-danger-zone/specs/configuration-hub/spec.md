# configuration-hub — spec delta

## ADDED Requirements

### Requirement: General page Danger zone
The Hub's **General** page SHALL provide a "Danger zone" section with selective, explicit reset controls:

- Four opt-in toggles, all default off, each gating one deletion category: **App data & settings** (the app's preferences domain, Application Support data excluding the AI model weights, and saved window state), **Caches**, **AI models** (the on-disk weights, with the AI opt-in turned off first), and **Permissions** (a TCC reset for every service the app can hold).
- A destructive **Clear selected** action that SHALL be disabled while no category is selected and SHALL require an explicit confirmation enumerating exactly what will happen before anything is deleted.
- WHEN App data & settings is selected and any native-gesture/Spaces backup exists, the relocations SHALL be restored FIRST (and the confirmation SHALL say so) — the wipe must never delete the backups while leaving the system relocated.
- WHEN App data & settings or Permissions was cleared, the app SHALL relaunch itself so the fresh process reads the cleared state (a data wipe re-enters first-run onboarding); cache/model-only clears SHALL report a non-blocking summary and stay running.
- A **Restore native gestures** action that restores every app-made gesture and Spaces relocation from its absent-aware backup, turns the corresponding opt-ins off, and states that a re-login finishes the trackpad changes.

#### Scenario: Nothing selected, nothing clearable
- **WHEN** the Danger zone is shown with no category toggled on
- **THEN** the Clear action is disabled and nothing is deleted

#### Scenario: Selective clear honors the selection
- **WHEN** the user selects only Caches and AI models and confirms
- **THEN** only the cache directories and the model weights are removed (the AI opt-in turning off first), preferences and permissions are untouched, and the app keeps running with a summary

#### Scenario: Data wipe restores gestures first
- **WHEN** App data & settings is selected while a trackpad relocation backup exists and the user confirms
- **THEN** the relocations are restored from their backups before any deletion, and the app relaunches into first-run onboarding

#### Scenario: Permissions reset
- **WHEN** the Permissions category is selected and confirmed
- **THEN** every TCC service the app can hold is reset for the app's bundle id and the app relaunches

#### Scenario: Restore-all gestures
- **WHEN** the user invokes Restore native gestures with backups present
- **THEN** the trackpad keys and Spaces setting return to their exact backed-up values (deleting previously-absent keys), the opt-ins turn off, and the user is told a re-login completes the trackpad changes
