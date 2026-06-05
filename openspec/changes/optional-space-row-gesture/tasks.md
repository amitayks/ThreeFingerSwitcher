## 1. Spike: confirm vertical gesture keys (blocking — gates D4)

- [ ] 1.1 Determine the exact `defaults` keys for the native three-finger vertical gesture in `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad` (candidates: `TrackpadThreeFingerVertSwipeGesture` / `TrackpadFourFingerVertSwipeGesture`), and whether `com.apple.dock` `showMissionControlGestureEnabled` / `showAppExposeGestureEnabled` are also required
- [ ] 1.2 Establish whether Mission Control (up) and App Exposé (down) share one key or are two keys, and record the value semantics (off / three-finger / four-finger)
- [ ] 1.3 Determine whether reassigning to four fingers takes effect live or requires re-login; if a live-apply path exists (driver notification), document it. This decision selects the D4 gating branch
- [ ] 1.4 Capture findings in `design.md` (resolve Open Question D-OQ1) before implementing

## 2. Vertical gesture config (system change)

- [ ] 2.1 Add a vertical-gesture config type (sibling of `TrackpadGestureConfig`, e.g. `VerticalGestureConfig`) operating on the two trackpad domains with the keys confirmed in task 1
- [ ] 2.2 Implement `currentState()` / `isClaimed`-equivalent read of whether the native three-finger vertical gesture is active
- [ ] 2.3 Implement relocate-to-four-fingers with an absent-aware JSON backup of every key changed (mirror `TrackpadGestureConfig.disableThreeFingerHorizontal` + `SpacesRearrangeConfig` absent-aware backup)
- [ ] 2.4 Implement faithful `restore()` (delete previously-absent keys, write back prior explicit values) and `hasBackup`
- [ ] 2.5 Implement an effective-state / `needsReloginWarning` signal per task 1.3 so emission can be gated on the change being effective
- [ ] 2.6 No-op guards: skip writes when already relocated; skip restore without a backup

## 3. Settings: the bound opt-in

- [ ] 3.1 Add a persisted `manageVerticalGesture` (working name) flag to `AppSettings`, default `false`
- [ ] 3.2 Expose it so `GestureRecognizer` and `AppCoordinator` can read the effective opt-in state

## 4. Recognizer gating

- [ ] 4.1 Gate vertical accumulation / `emitRowStep` in `GestureRecognizer.update()` on the effective opt-in being enabled
- [ ] 4.2 Ensure that when the opt-in is off, post-activation vertical motion is fully ignored (no row steps, vertical left to the OS) — preserving horizontal behavior unchanged
- [ ] 4.3 Ensure pre-activation vertical still yields to the OS regardless of the opt-in

## 5. Coordinator wiring (lifecycle + consent)

- [ ] 5.1 Observe the `manageVerticalGesture` toggle (`dropFirst`) and apply/restore the vertical config, mirroring `observeSpacesRearrangeToggle` / `handleSpacesRearrangeToggle`
- [ ] 5.2 Apply on launch when the opt-in is set (mirror `applySpacesRearrangeOnLaunchIfManaged`)
- [ ] 5.3 Restore on quit when changed this session (mirror `restoreSpacesRearrangeOnQuit`)
- [ ] 5.4 First-run consent prompt explaining Mission Control / App Exposé move to four fingers and may need a re-login (mirror `maybePromptSpacesRearrange` / `promptNativeGestureSetup`); enabling the opt-in is the consent action
- [ ] 5.5 Implement the D4 emission gate: enable row stepping immediately if the change is live, otherwise defer to the next launch (post re-login) per task 1.3
- [ ] 5.6 Surface the non-fatal "couldn't change the setting" warning for managed/MDM Macs (mirror `applySpacesRearrange`)

## 6. UI

- [ ] 6.1 Add the "Space-row switching" opt-in to `SettingsView`, with help text on the four-finger relocation and re-login caveat
- [ ] 6.2 Add an onboarding entry for it in `OnboardingView` (mirror the spaces-rearrange / native-gesture rows), wired through `showOnboarding`
- [ ] 6.3 Ensure the existing row-step tunables (row-step distance, reverse-vertical) read as gated by the opt-in in the UI

## 7. Tests

- [ ] 7.1 `GestureRecognizerTests`: row steps emitted when opt-in effective; no row steps when off (vertical yielded); pre-activation vertical always yielded
- [ ] 7.2 Vertical-config tests mirroring `TrackpadGestureConfigTests` / `SpacesRearrangeConfigTests`: backup/restore, absent-aware delete, no-op guards (pure decision logic, no system access)
- [ ] 7.3 Settings test: `manageVerticalGesture` defaults to false and persists

## 8. Manual verification

- [ ] 8.1 With opt-in off: confirm native three-finger Mission Control / App Exposé work and the switcher never steals vertical
- [ ] 8.2 With opt-in on (after any required re-login): confirm vertical row switching works and the OS never fires Mission Control / App Exposé mid-overlay (the original bug, on both up and down)
- [ ] 8.3 Toggle off and on, and quit/relaunch: confirm the trackpad setting is restored exactly and reapplied, and Mission Control returns to three fingers when off
