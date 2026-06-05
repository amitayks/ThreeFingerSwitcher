## 1. SpacesRearrangeConfig (the system-setting seam)

- [x] 1.1 Add `Sources/ThreeFingerSwitcher/NativeGesture/SpacesRearrangeConfig.swift` (sibling of `TrackpadGestureConfig`), reusing the `/usr/bin/defaults` shell-helper approach via a small `runDefaults` runner.
- [x] 1.2 Implement `currentState()` reading `com.apple.dock mru-spaces`, mapping absent → enabled (default ON), `1`/`true` → enabled, `0`/`false` → disabled.
- [x] 1.3 Implement `killallDock()` (run `/usr/bin/killall Dock`, wait for exit) and a `disableAutoRearrange()` that backs up the prior state, writes `mru-spaces=false`, and restarts the Dock; return success/failure.
- [x] 1.4 Implement absent-aware backup: persist prior state as one of `{absent, true, false}` in `UserDefaults` (do not overwrite an existing backup).
- [x] 1.5 Implement `restore()` that deletes the key when the prior state was absent, writes the value otherwise, restarts the Dock, clears the backup; expose `hasBackup` / `changedThisSession`.
- [x] 1.6 Make every mutate a no-op (no write, no Dock restart) when the value already matches the target.

## 2. Persisted opt-in

- [x] 2.1 Add `manageSpacesRearrange` (Bool) to `AppSettings` with a `Defaults` value and `Keys` entry, persisted like the other flags. (Deliberately excluded from `resetToDefaults()` so "Reset" never silently changes a system setting.)

## 3. Lifecycle wiring in AppCoordinator

- [x] 3.1 Own a `SpacesRearrangeConfig` instance in `AppCoordinator`.
- [x] 3.2 On `start()`/launch: if `manageSpacesRearrange` is enabled, apply the setting (no-op when already disabled).
- [x] 3.3 First-run consent: add a `maybePromptSpacesRearrange()` that prompts once (persist that we asked), explains the system-wide effect, and on accept sets `manageSpacesRearrange = true` and applies; mirror `maybePromptNativeGestureSetup`.
- [x] 3.4 On quit: restore the original value synchronously if changed this session (extend the existing terminate/quit path next to `offerRestoreOnQuit`), waiting for the Dock restart to finish before exit.
- [x] 3.5 When the Settings toggle is turned off, restore immediately and stop managing on future launches. (Driven by a Combine observer on `AppSettings.$manageSpacesRearrange`, so the dumb `SettingsView` toggle works.)

## 4. UI surfaces

- [x] 4.1 `OnboardingView`: add a status row (auto-rearrange on → action to turn off; off → confirmation), parallel to the "Native gesture" GroupBox, wired through `AppCoordinator`.
- [x] 4.2 `SettingsView`: add a toggle bound to `AppSettings.manageSpacesRearrange` with a short explanation of the system-wide effect.

## 5. Failure handling

- [x] 5.1 Surface a non-fatal warning (e.g. `infoAlert`) when the write or Dock restart fails (managed preference), without crashing or blocking the switcher.

## 6. Verify

- [x] 6.1 `swift build` and `swift test` pass (128 tests, 0 failures; 10 new pure-logic tests for the absent-aware state machine in `SpacesRearrangeConfigTests`).
- [~] 6.2 `INSTALL=1 ./scripts/build-app.sh` **done** (fresh app installed to /Applications). Manual check pending (user): first run prompts for consent; accepting sets `mru-spaces=false` + restarts Dock; moving between Spaces no longer reorders them.
- [ ] 6.3 Manual lifecycle check (user): quitting restores the prior value (Mission Control rearranges again); relaunching reapplies; declining consent changes nothing.
- [x] 6.4 Run `openspec validate disable-spaces-auto-rearrange`. (Valid.)
