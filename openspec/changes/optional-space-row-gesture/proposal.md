## Why

Once the switcher is active, vertical finger motion drives Space-row switching — but the OS's native three-finger Mission Control (up) and App Exposé (down) recognizers stay enabled and run in parallel on the same passive touch stream. A vertical excursion mid-overlay therefore intermittently fires the native gesture and "steals" the swipe even though the switcher is already showing. The app reads touches passively (`OpenMultitouchSupport` cannot consume them) and trackpad-gesture defaults can't be toggled live, so the only robust fix is to disable the native vertical gesture — but only for users who actually want row-switching, since doing so moves their Mission Control / App Exposé to four fingers.

## What Changes

- Introduce a single opt-in — **"Space-row switching"** (default **off**) — that binds two things into one switch so they can never be independently on:
  - the recognizer emitting **vertical row steps** after activation, and
  - **reassigning the native three-finger vertical gesture** (Mission Control / App Exposé) to four fingers.
- **When off (default):** the recognizer fully yields vertical motion to the OS even after activation; native Mission Control / App Exposé keep working on three fingers. The conflict cannot occur because the app never uses the vertical axis.
- **When on:** back up and reassign the native three-finger vertical gesture to four fingers; restore the original value on quit; reapply on relaunch — mirroring `spaces-rearrange-config`. Includes a first-run consent prompt, an onboarding entry, and a re-login warning, mirroring the existing horizontal-gesture flow.
- Gate vertical row-step **emission** so the feature only goes live once the system change is actually effective, avoiding a temporary window where row-stepping is active while the OS still owns the vertical gesture (exact gating mechanism resolved in design).
- **BREAKING (behavioral):** vertical Space-row switching is now off by default. Users who relied on it must enable the new opt-in.

## Capabilities

### New Capabilities

_None — this extends existing capabilities rather than introducing a new one._

### Modified Capabilities

- `gesture-recognition`: vertical row-stepping after activation becomes **conditional on the opt-in**. When the opt-in is off, the recognizer yields vertical motion to the OS even after horizontal activation (no row steps).
- `native-gesture-config`: gains optional disable/restore of the **native three-finger vertical** gesture (Mission Control / App Exposé → four fingers), with consent, lifecycle management (apply-on-launch / restore-on-quit / reapply-on-relaunch), and re-login detection. The current guarantee that "Mission Control and App Exposé remain intact" becomes conditional on this opt-in.
- `tunable-settings`: gains the **"Space-row switching" opt-in**, the single switch that binds the recognizer feature-gate and the native-vertical-gesture change together so the conflict seam cannot exist.

## Impact

- **Code:**
  - `Gesture/GestureRecognizer.swift` — gate `emitRowStep` / vertical accumulation on the opt-in.
  - `Settings/AppSettings.swift` — new persisted flag; surfaces the opt-in.
  - `App/AppCoordinator.swift` — consent prompt, observe the toggle (apply/restore), launch-apply-if-managed, quit-restore, onboarding wiring (mirrors the `manageSpacesRearrange` plumbing).
  - `NativeGesture/` — a vertical-gesture config (sibling of `TrackpadGestureConfig`, or an extension of it) that reads/disables/restores the vertical keys with backup.
  - `Permissions/OnboardingView.swift`, `Settings/SettingsView.swift` — UI for the opt-in and its re-login warning.
- **System settings touched (needs a confirming spike):** `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad` vertical keys (likely `TrackpadThreeFingerVertSwipeGesture` / `TrackpadFourFingerVertSwipeGesture`), and possibly `com.apple.dock` Mission Control / App Exposé gesture bools. Whether the change can apply live or requires re-login must be confirmed.
- **Tests:** `GestureRecognizerTests` (row-step gating on/off), plus a config test mirroring `TrackpadGestureConfigTests` / `SpacesRearrangeConfigTests` (backup/restore/absent-aware).
