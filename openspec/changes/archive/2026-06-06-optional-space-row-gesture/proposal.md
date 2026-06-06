## Why

Once the switcher is active, vertical finger motion drives Space-row switching — but the OS's native three-finger Mission Control (up) and App Exposé (down) recognizers stay enabled and run in parallel on the same passive touch stream. A vertical excursion mid-overlay therefore intermittently fires the native gesture and "steals" the swipe even though the switcher is already showing. The app reads touches passively (`OpenMultitouchSupport` cannot consume them) and trackpad-gesture defaults can't be toggled live, so the only robust fix is to disable the native vertical gesture — but only for users who actually want row-switching, since doing so moves their Mission Control / App Exposé to four fingers.

## What Changes

- Introduce a single opt-in — **"Space-row switching"** (default **off**) — that binds two things into one switch so they can never be independently on:
  - the recognizer emitting **vertical row steps** after activation, and
  - **reassigning the native three-finger vertical gesture** (Mission Control / App Exposé) to four fingers.
- **When off (default):** the recognizer fully yields vertical motion to the OS even after activation; native Mission Control / App Exposé keep working on three fingers. The conflict cannot occur because the app never uses the vertical axis.
- **When on:** back up and reassign the native three-finger vertical gesture to four fingers; reapply on relaunch; **keep it applied across logout/restart** and restore the original value only when the user turns the opt-in off (or picks Restore from the menu) — mirroring the horizontal `native-gesture-config` model, because the change needs a re-login and a quit-time restore would undo it on the very logout that applies it. Includes a first-run consent prompt, an onboarding entry, and a re-login warning.
- Gate vertical row-step **emission** so the feature only goes live once the system change is actually effective, avoiding a temporary window where row-stepping is active while the OS still owns the vertical gesture (exact gating mechanism resolved in design).
- **Runtime gesture ownership (added after on-device testing — see design "Update" section):** freeing the OS three-finger vertical (`TrackpadThreeFingerVertSwipeGesture = 0`) turns it into a plain scroll, which (a) leaked to the background window during overlay row-switching and (b) removed idle three-finger Mission Control / App Exposé. So, when the opt-in is effective, the app now **owns the freed gesture at runtime**: a session scroll tap consumes the three-finger scroll (Accessibility only — no new permission), and a fresh idle vertical swipe **synthesizes Mission Control (up) / App Exposé (down)** itself via `CoreDockSendNotification`. Four-finger vertical keeps native Mission Control as a fallback (`TrackpadFourFingerVertSwipeGesture = 2`), but the user no longer needs it — idle three-finger MC works because we trigger it, not the OS.
- **BREAKING (behavioral):** vertical Space-row switching is now off by default. Users who relied on it must enable the new opt-in.

## Capabilities

### New Capabilities

- `runtime-gesture-ownership`: when the opt-in is effective, the app owns the freed three-finger vertical gesture at runtime — a session scroll tap consumes the three-finger scroll so it never leaks to the background, and idle three-finger up/down is synthesized into Mission Control / App Exposé. Accessibility-only; no per-use re-login.

### Modified Capabilities

- `gesture-recognition`: vertical row-stepping after activation becomes **conditional on the opt-in**; when off, the recognizer yields vertical motion to the OS. When the opt-in is effective, a fresh idle vertical swipe (pre-activation) emits a one-shot Mission Control / App Exposé intent instead of yielding.
- `native-gesture-config`: gains optional disable/restore of the **native three-finger vertical** gesture (Mission Control / App Exposé → four fingers), with consent, lifecycle management (apply-on-launch / reapply-on-relaunch / persist-across-logout / restore-on-opt-out), and re-login detection. The current guarantee that "Mission Control and App Exposé remain intact" becomes conditional on this opt-in.
- `tunable-settings`: gains the **"Space-row switching" opt-in**, the single switch that binds the recognizer feature-gate and the native-vertical-gesture change together so the conflict seam cannot exist.

## Impact

- **Code:**
  - `Gesture/GestureRecognizer.swift` — gate `emitRowStep` / vertical accumulation on the opt-in.
  - `Settings/AppSettings.swift` — new persisted flag; surfaces the opt-in.
  - `App/AppCoordinator.swift` — consent prompt, observe the toggle (apply on enable / restore on disable), launch-apply-if-managed, the effective-gate that drives `GestureRecognizer.rowSwitchingEnabled`, onboarding wiring (mirrors the `manageSpacesRearrange` plumbing, minus restore-on-quit).
  - `NativeGesture/VerticalGestureConfig.swift` — reads/disables/restores `TrackpadThreeFingerVertSwipeGesture` (both trackpad domains) with absent-aware backup.
  - `NativeGesture/MissionControl.swift` — synthesizes Mission Control / App Exposé via `CoreDockSendNotification` (Carbon `dlopen`, crash-safe).
  - `TouchInput/ScrollEventTap.swift` — session `CGEventTap` that consumes scroll while ≥3 fingers are down.
  - `Permissions/OnboardingView.swift`, `Settings/SettingsView.swift` — UI for the opt-in and its re-login warning.
- **System settings touched (confirmed by on-device `defaults` diff):** `TrackpadThreeFingerVertSwipeGesture` in `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad` — `2` (three-finger enabled) → `0` (freed to scroll). The `com.apple.dock` keys are on/off booleans (not finger count) and are NOT touched. The change needs a one-time re-login to take runtime effect.
- **Permissions:** the runtime scroll tap needs only **Accessibility** (already held for window raising) — confirmed live; Input Monitoring is not required.
- **Tests:** `GestureRecognizerTests` (row-step gating + idle-vertical → Mission Control), `VerticalGestureConfigTests` (backup/restore/absent-aware, mirroring `SpacesRearrangeConfigTests`), `AppSettingsTests` (opt-in default/persist/reset).
