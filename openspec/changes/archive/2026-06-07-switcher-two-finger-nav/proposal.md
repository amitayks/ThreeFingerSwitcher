## Why

The four-finger launcher already lets you trigger with four fingers and then relax to two while you navigate — a far more comfortable hold than pinning all four fingers down through the whole gesture. The three-finger window switcher has no such relaxation: you must keep three fingers planted from trigger to commit. Mirroring the launcher's post-activation relaxation onto the switcher makes scrubbing the window grid (and stepping Space-rows) ergonomically identical to the launcher, with no new trigger to learn.

## What Changes

- The window switcher is still **triggered** by a deliberate three-finger horizontal swipe (unchanged). Once the overlay is up (post-activation), the gesture **stays alive while two or three fingers remain in contact**, so the user can relax to two fingers and keep navigating the horizontal/vertical grid, then lift to commit.
- After activation, the step reference origin is **re-baselined on every contact-count change** (e.g. three fingers relaxing to two) so the centroid shift from a leaving finger emits no spurious step — exactly as the launcher already does.
- The session scroll event tap **runs while the switcher is enabled** and its consume rule gains a **switcher-overlay-open clause**, so the two-finger movement that drives navigation while the overlay is visible is captured and does not scroll the window underneath. With the overlay closed, normal two-finger scrolling passes through unchanged.
- **Pre-activation behavior is unchanged**: the trigger still requires three fingers; dropping below three before the overlay appears cancels exactly as before. No new setting, no native-gesture relocation, no re-login, no new permission. Holding three fingers the whole way behaves exactly as today.

## Capabilities

### New Capabilities
<!-- None — this extends existing switcher behavior. -->

### Modified Capabilities
- `gesture-recognition`: after horizontal activation, the three-finger switcher gesture remains alive while two or more contacts remain (capped at the existing too-many rule), re-baselining the step origin on contact-count change and ending below two contacts. Pre-activation detection and the three-finger trigger are unchanged.
- `runtime-gesture-ownership`: the session scroll event tap also runs while the switcher is enabled, and its consume rule additionally consumes scroll while the switcher overlay is open, so two-finger navigation does not leak to the background window.

## Impact

- `Sources/ThreeFingerSwitcher/Gesture/GestureRecognizer.swift` — `trackSwitcher` post-activation relaxation + a `switcherContacts` re-baseline (mirrors `trackLauncher` / `launcherContacts`).
- `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` — extend `shouldConsumeScroll` with a `switcherOpen` clause; run the scroll tap while the switcher is enabled (in addition to the row/launcher gates).
- No changes to `AppSettings`, the native-gesture configs, permissions, or the overlay UI. Three-finger-only users see no behavioral change.
