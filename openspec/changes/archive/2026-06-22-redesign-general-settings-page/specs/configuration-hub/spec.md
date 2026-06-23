## ADDED Requirements

### Requirement: General page consolidated preference settings
The Hub's **General** page SHALL present its preference settings — **Self-heal focus after switching**, **Open at Login**, and **Show diagnostic tools** — as a single consolidated section of switch-style rows (each a title with an optional explanatory caption and a right-aligned on/off switch), rather than as separate one-toggle sections. The **Show diagnostic tools** toggle SHALL control only the *visibility* of the diagnostic actions in the menu-bar status menu; the General page SHALL NOT host the **Write Diagnostics** or **Copy Focus Log** action buttons themselves.

#### Scenario: Preferences shown as one switch section
- **WHEN** the user opens the General page
- **THEN** Self-heal focus after switching, Open at Login, and Show diagnostic tools appear together in one section as switch rows, and no Write Diagnostics / Copy Focus Log buttons appear on the page

#### Scenario: Diagnostics toggle gates the menu, not the page
- **WHEN** the user turns Show diagnostic tools on or off
- **THEN** the persisted show-diagnostics preference flips, the diagnostic action buttons remain absent from the General page, and only the menu-bar status menu's diagnostic group appears (on) or disappears (off)

## MODIFIED Requirements

### Requirement: General page Danger zone
The Hub's **General** page SHALL provide a "Danger zone" section with selective, explicit reset controls:

- Four opt-in selectors, all default off, each gating one deletion category: **App data & settings** (the app's preferences domain, Application Support data excluding the AI model weights, and saved window state), **Caches**, **AI models** (the on-disk weights, with the AI opt-in turned off first), and **Permissions** (a TCC reset for every service the app can hold). The selectors SHALL be presented as a 2×2 grid of full-body toggle-cards: the whole card is the click target, and a selected card is visually highlighted (distinct from a plain on/off switch).
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

#### Scenario: Selectors are a 2×2 toggle-card grid
- **WHEN** the Danger zone is shown
- **THEN** the four category selectors appear as a 2×2 grid of full-body toggle-cards where clicking anywhere on a card toggles its selection and the selected card is highlighted
