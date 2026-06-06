## 1. Spike: confirm vertical gesture keys (blocking — gates D4)

- [x] 1.1 Determine the exact `defaults` keys for the native three-finger vertical gesture in `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad` (candidates: `TrackpadThreeFingerVertSwipeGesture` / `TrackpadFourFingerVertSwipeGesture`), and whether `com.apple.dock` `showMissionControlGestureEnabled` / `showAppExposeGestureEnabled` are also required — **RESOLVED by on-machine before/after diff: the lever is `TrackpadThreeFingerVertSwipeGesture` in BOTH trackpad domains. The `com.apple.dock` keys are pure on/off booleans (stayed `1`), NOT finger count, and are not touched.**
- [x] 1.2 Establish whether Mission Control (up) and App Exposé (down) share one key or are two keys, and record the value semantics (off / three-finger / four-finger) — **RESOLVED: ONE linked trackpad key controls both up (Mission Control) and down (App Exposé). Values: `2` = three-finger enabled (OS owns it), `0` = freed (four fingers); `TrackpadFourFingerVertSwipeGesture` stays `2`.**
- [x] 1.3 Determine whether reassigning to four fingers takes effect live or requires re-login; if a live-apply path exists (driver notification), document it. This decision selects the D4 gating branch — **RESOLVED: the trackpad key needs a RE-LOGIN (stored value flips to `0` immediately but three-finger vertical keeps firing until logout — observed directly). → detect-and-warn / defer emission (D4 re-login path).**
- [x] 1.4 Capture findings in `design.md` (resolve Open Question D-OQ1) before implementing — **DONE (D2, D4, D-OQ1 updated)**

## 2. Vertical gesture config (system change)

- [x] 2.1 Add a vertical-gesture config type (sibling of `TrackpadGestureConfig`, e.g. `VerticalGestureConfig`) operating on the two trackpad domains with the keys confirmed in task 1
- [x] 2.2 Implement `currentState()` / `isClaimed`-equivalent read of whether the native three-finger vertical gesture is active
- [x] 2.3 Implement relocate-to-four-fingers with an absent-aware JSON backup of every key changed (mirror `TrackpadGestureConfig.disableThreeFingerHorizontal` + `SpacesRearrangeConfig` absent-aware backup)
- [x] 2.4 Implement faithful `restore()` (delete previously-absent keys, write back prior explicit values) and `hasBackup`
- [x] 2.5 Implement an effective-state / `needsReloginWarning` signal per task 1.3 so emission can be gated on the change being effective
- [x] 2.6 No-op guards: skip writes when already relocated; skip restore without a backup

## 3. Settings: the bound opt-in

- [x] 3.1 Add a persisted `manageVerticalGesture` (working name) flag to `AppSettings`, default `false`
- [x] 3.2 Expose it so `GestureRecognizer` and `AppCoordinator` can read the effective opt-in state

## 4. Recognizer gating

- [x] 4.1 Gate vertical accumulation / `emitRowStep` in `GestureRecognizer.update()` on the effective opt-in being enabled
- [x] 4.2 Ensure that when the opt-in is off, post-activation vertical motion is fully ignored (no row steps, vertical left to the OS) — preserving horizontal behavior unchanged
- [x] 4.3 Ensure pre-activation vertical still yields to the OS regardless of the opt-in

## 5. Coordinator wiring (lifecycle + consent)

- [x] 5.1 Observe the `manageVerticalGesture` toggle (`dropFirst`) and apply/restore the vertical config, mirroring `observeSpacesRearrangeToggle` / `handleSpacesRearrangeToggle`
- [x] 5.2 Apply on launch when the opt-in is set (mirror `applySpacesRearrangeOnLaunchIfManaged`)
- [x] 5.3 Restore on quit when changed this session (mirror `restoreSpacesRearrangeOnQuit`)
- [x] 5.4 First-run consent prompt explaining Mission Control / App Exposé move to four fingers and may need a re-login (mirror `maybePromptSpacesRearrange` / `promptNativeGestureSetup`); enabling the opt-in is the consent action
- [x] 5.5 Implement the D4 emission gate: enable row stepping immediately if the change is live, otherwise defer to the next launch (post re-login) per task 1.3
- [x] 5.6 Surface the non-fatal "couldn't change the setting" warning for managed/MDM Macs (mirror `applySpacesRearrange`)

## 6. UI

- [x] 6.1 Add the "Space-row switching" opt-in to `SettingsView`, with help text on the four-finger relocation and re-login caveat
- [x] 6.2 Add an onboarding entry for it in `OnboardingView` (mirror the spaces-rearrange / native-gesture rows), wired through `showOnboarding`
- [x] 6.3 Ensure the existing row-step tunables (row-step distance, reverse-vertical) read as gated by the opt-in in the UI

## 7. Tests

- [x] 7.1 `GestureRecognizerTests`: row steps emitted when opt-in effective; no row steps when off (vertical yielded); pre-activation vertical always yielded
- [x] 7.2 Vertical-config tests mirroring `TrackpadGestureConfigTests` / `SpacesRearrangeConfigTests`: backup/restore, absent-aware delete, no-op guards (pure decision logic, no system access)
- [x] 7.3 Settings test: `manageVerticalGesture` defaults to false and persists

## 8. Manual verification (disable-only approach)

- [x] 8.1 With opt-in off: confirm native three-finger Mission Control / App Exposé work and the switcher never steals vertical
- [x] 8.2 With opt-in on (after re-login): confirm vertical row switching works and the OS never fires Mission Control / App Exposé mid-overlay (the original bug, on both up and down) — **confirmed on-device; but surfaced two side effects (background scroll + lost idle MC) that motivated section 9**
- [x] 8.3 Toggle off and on: confirm the trackpad setting is restored and native Mission Control returns when off

## 9. Runtime gesture ownership (added after on-device testing — see design "Update" section)

Disabling the OS three-finger vertical turns it into a scroll, which leaked to the background during the overlay and removed idle three-finger Mission Control. Resolution: own the freed gesture at runtime.

- [x] 9.1 Spike: confirm `CoreDockSendNotification` opens Mission Control / App Exposé — **proven live** (Carbon must be `dlopen`'d; `import Carbon` doesn't force-load it)
- [x] 9.2 Spike: confirm a session `CGEventTap` consumes the three-finger scroll inside the signed app — **proven live** (active(consume), scroll suppressed; needs only **Accessibility**, NOT Input Monitoring)
- [x] 9.3 `MissionControl` helper — `CoreDockSendNotification` resolved crash-safely (missing symbol ⇒ no-op)
- [x] 9.4 `ScrollEventTap` (active session tap) + coordinator consume-predicate (≥3 fingers down) + lifecycle (runs only while effective & enabled)
- [x] 9.5 `GestureRecognizer` idle-vertical path: fresh vertical (pre-activation) emits a one-shot Mission Control (up) / App Exposé (down) intent when the feature owns the gesture; yields to the OS when off
- [x] 9.6 Tests: idle-vertical → Mission Control / App Exposé (up/down, once-per-gesture, below-threshold, gated off)
- [x] 9.7 Strip spike scaffolding (in-app scroll-tap probe + menu item + `EventTapSpike` target)

## 10. Manual verification (runtime ownership) — confirmed on-device

- [x] 10.1 Idle three-finger up → Mission Control; idle three-finger down → App Exposé (synthesized)
- [x] 10.2 Overlay three-finger up/down → Space-row switch, background window does NOT scroll
- [x] 10.3 Two-finger scroll unaffected; native Mission Control restored when the opt-in is off

## Notes for future sessions

- **Signing:** the agent's sandboxed shell has no keychain access → it can only produce **ad-hoc** builds, which break TCC (Accessibility) and the app. In-app testing must use a **stable-signed** build from the user's own Terminal: `INSTALL=1 ./scripts/build-app.sh` (auto-uses the `ThreeFingerSwitcher Dev` cert; run `./scripts/make-dev-cert.sh` once if it's missing). Agent does code + `swift build`/`swift test` only.
- **Final mechanism:** opt-in ON → `TrackpadThreeFingerVertSwipeGesture = 0` (one-time re-login) → runtime: scroll tap consumes three-finger scroll + `GestureRecognizer`/`MissionControl` synthesize idle MC/Exposé + post-activation vertical steps Space-rows. Opt-in OFF → native three-finger Mission Control, horizontal-only switcher.
