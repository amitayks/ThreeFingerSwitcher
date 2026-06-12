# Tasks — hub-danger-zone

## 1. Core reset service

- [x] 1.1 `Settings/AppDataReset.swift`: `DangerZoneSelection` option set + pure `filesystemTargets(...)` (whole-dir removals vs. remove-contents-except-models per the App-data/AI-models split) + the TCC service list. Unit-test all selection combinations.
- [x] 1.2 The perform step behind seams: prefs via `removePersistentDomain` (last), directory removal via FileManager, `tccutil reset` per service via an injectable command runner; per-step outcome collection (non-fatal failures).

## 2. Coordinator flow

- [x] 2.1 `restoreAllNativeGestures()`: flip the three opt-ins off (observers restore absent-aware + clear markers), restore the horizontal backup, refresh gates; interactive summary with the re-login note.
- [x] 2.2 `dangerZoneClear(selection)`: confirmation alert enumerating the selection (+ restore-first and relaunch notes); restore-first when App data selected with backups; stop monitors; AI opt-out before weights deletion; prefs wiped last; relaunch when App data/Permissions cleared, summary otherwise.

## 3. Hub UI

- [x] 3.1 GeneralPage "Danger zone" section: four captioned toggles, destructive Clear selected… (disabled when empty), Restore native gestures…; HubContext closures wired in `makeHubContext`.

## 4. Verification & hygiene

- [x] 4.1 `swift build` + `swift test` green; xcodebuild compile-only.
- [x] 4.2 Sync the configuration-hub delta into the canonical spec; extend MANUAL-TEST coverage (selective clear, restore-first, relaunch-into-wizard, tccutil results).
