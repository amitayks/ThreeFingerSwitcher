## MODIFIED Requirements

### Requirement: General page Danger zone
The Hub's **General** page SHALL provide a "Danger zone" section with selective, explicit reset controls:

- Opt-in selectors, all default off, each gating one deletion category: **App data & settings** (the app's preferences domain, Application Support data, and saved window state), **Caches**, and **Permissions** (a TCC reset for every service the app can hold). The selectors SHALL be presented as a grid of full-body toggle-cards: the whole card is the click target, and a selected card is visually highlighted (distinct from a plain on/off switch).
- A destructive **Clear selected** action that SHALL be disabled while no category is selected and SHALL require an explicit confirmation enumerating exactly what will happen before anything is deleted.
- WHEN App data & settings is selected and any native-gesture/Spaces backup exists, the relocations SHALL be restored FIRST and **synchronously** — the restore SHALL have completed before any deletion begins, never deferred to a later run-loop turn that the wipe could outrun (and the confirmation SHALL say so) — the wipe must never delete the backups while leaving the system relocated.
- Before deleting, the clipboard recorder SHALL be stopped and its pending persistence drained, so a queued write cannot recreate the history being removed.
- WHEN App data & settings or Permissions was cleared, the app SHALL relaunch itself so the fresh process reads the cleared state (a data wipe re-enters first-run onboarding); cache/model-only clears SHALL report a non-blocking summary and stay running.
- A **Restore native gestures** action that restores every app-made gesture and Spaces relocation from its absent-aware backup, turns the corresponding opt-ins off, and states that a re-login finishes the trackpad changes.

#### Scenario: Nothing selected, nothing clearable
- **WHEN** the Danger zone is shown with no category toggled on
- **THEN** the Clear action is disabled and nothing is deleted

#### Scenario: Selective clear honors the selection
- **WHEN** the user selects only Caches and confirms
- **THEN** only the cache directories are removed, preferences and permissions are untouched, and the app keeps running with a summary

#### Scenario: Data wipe restores gestures first
- **WHEN** App data & settings is selected while a trackpad relocation backup exists and the user confirms
- **THEN** the relocations are restored from their backups, synchronously, before any deletion, and the app relaunches into first-run onboarding

#### Scenario: Data wipe cannot be resurrected by a queued clipboard write
- **WHEN** a clipboard persistence write is still queued when the user confirms a data wipe
- **THEN** the write lands before the deletion, and the relaunched app starts with no clipboard history

#### Scenario: Permissions reset
- **WHEN** the Permissions category is selected and confirmed
- **THEN** every TCC service the app can hold is reset for the app's bundle id and the app relaunches

#### Scenario: Restore-all gestures
- **WHEN** the user invokes Restore native gestures with backups present
- **THEN** the trackpad keys and Spaces setting return to their exact backed-up values (deleting previously-absent keys), the opt-ins turn off, and the user is told a re-login completes the trackpad changes
