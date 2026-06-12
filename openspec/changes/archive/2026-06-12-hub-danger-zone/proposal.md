# Hub Danger Zone — selective reset + restore-all-gestures

## Why

Removing or resetting the app today requires a hand-written shell ritual (defaults/file deletions, `tccutil` resets, and a factory-reset fallback for the trackpad keys) because nothing in the app can selectively clear its own footprint — and the ritual exists partly because wiping app data destroys the gesture backups, stranding the relocated trackpad settings with no in-app restore path. The app should own its own clean exit.

## What Changes

- **Hub → General gains a "Danger zone" section** with:
  - Four opt-in toggles (all default off), each gating one category of deletion: **App data & settings** (preferences domain, Application Support except models, saved window state), **Caches** (Caches + HTTPStorages), **AI models** (the multi-GB weights directory, with the AI opt-in turned off first), **Permissions** (`tccutil reset` for every service the app can hold).
  - A destructive **Clear selected…** button (disabled while nothing is selected) with an explicit confirmation listing exactly what will happen.
  - A **Restore native gestures…** button that restores every gesture/Spaces relocation from its backup and turns the opt-ins off.
- **Backup-stranding protection**: when App data & settings is selected and any gesture backup exists, the relocations are restored FIRST (stated in the confirmation), so the wipe can never delete the backups while leaving the system relocated.
- **Fresh-state relaunch**: clearing App data or Permissions ends in the app relaunching itself — the fresh process reads the cleared state (a data wipe replays the First Touch wizard, a true fresh-install experience). Cache/model-only clears stay in place with a summary.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `configuration-hub`: the General page gains the Danger zone requirement (selective opt-in deletion categories, confirmation, restore-gestures-first rule, relaunch-after semantics, restore-all-gestures action).

## Impact

- New `Settings/AppDataReset.swift` in Core: selection model + pure filesystem-target computation (unit-tested) + the perform step behind seams (`tccutil` via Process, prefs via `removePersistentDomain`).
- `AppCoordinator`: confirmation flow, restore-first ordering, machinery shutdown before the wipe, relaunch-after wiring; `restoreAllNativeGestures()`.
- `Hub/HubFeaturePages.swift` (GeneralPage) + `HubContext`: the section UI and closures.
- Tests: selection/path computation, restore-first decision, tcc service list.
