## Why

The `stable-space-row-order` change made the switcher's Space-rows follow Mission Control order, but macOS's "Automatically rearrange Spaces based on most recent use" (`com.apple.dock` key `mru-spaces`, default ON) keeps mutating that order as the user navigates — moving to a Space slides it toward the front. Because the switcher reads the live Mission Control order, the OS reshuffle reintroduces exactly the instability we just removed. The only way to make the order truly stable is to stop macOS from rearranging Spaces.

## What Changes

- Add a managed, opt-in system tweak that sets `com.apple.dock mru-spaces = false` (and restarts the Dock so it takes effect), so Mission Control — and therefore the switcher — keeps a fixed Space order.
- Prompt the user for consent on first run, mirroring the existing native-gesture consent flow (no silent forcing of a system setting).
- Manage the setting around the app's lifetime: when the opt-in is enabled, **apply on launch**, **restore the original value on quit**, and **reapply on relaunch** — so the OS setting is changed only while the app is running.
- Back up the prior value (including the common "key absent / default" state) so restore returns the system to exactly its original behavior.
- Expose a persistent toggle in Settings and a status row in the onboarding window.

## Capabilities

### New Capabilities

- `spaces-rearrange-config`: read, disable (with Dock restart), back up, and restore the macOS "rearrange Spaces by recent use" setting; manage it across the app lifecycle (apply on launch, restore on quit) with first-run consent and a persistent toggle.

### Modified Capabilities

_None._ (Consent and the onboarding/settings surfaces are specified within the new capability, parallel to how `native-gesture-config` owns its own consent.)

## Impact

- New `Sources/ThreeFingerSwitcher/.../SpacesRearrangeConfig.swift` (or sibling of `NativeGesture/TrackpadGestureConfig.swift`): reuses the `/usr/bin/defaults` shell-helper + UserDefaults backup approach, adds a `killall Dock` apply step and absent-key-aware restore.
- `App/AppCoordinator.swift`: apply on launch / restore on quit, plus the first-run consent prompt (alongside `maybePromptNativeGestureSetup` / `offerRestoreOnQuit`).
- `Settings/AppSettings.swift`: a persisted opt-in flag (e.g. `manageSpacesRearrange`).
- `Permissions/OnboardingView.swift` and `Settings/SettingsView.swift`: a status row / toggle.
- Relies on the app being **unsandboxed** (already true) to write `com.apple.dock` and run `killall Dock`. No new permissions or TCC prompts. The setting change is system-global (affects Mission Control everywhere), which the consent copy must state.
