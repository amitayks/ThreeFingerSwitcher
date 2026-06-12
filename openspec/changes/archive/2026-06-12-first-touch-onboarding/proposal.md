# First Touch — a gesture-driven first-run onboarding

## Why

A new user's first contact with the app today is hostile to everything the app actually is: up to 4–7 consecutive modal `NSAlert`s of dense text (each one-shot — "Not now" is permanent), then a cold Hub Setup page asking for permissions **before the user has ever seen what they unlock**, an Accessibility prompt that fires mid-gesture on their very first swipe, an undocumented quit-and-reopen requirement for Screen Recording, and up to three separate "restart to finish" moments because each gesture relocation is applied piecemeal (their writes even collide on the shared four-finger keys). Users install the app, get lost, and never reach the magic.

The fix is enabled by three facts already true of the codebase: the multitouch read works **before any permission is granted**; the overlay views (`SwitcherView`/`LauncherView`) are pure presentation over fake-able models and can be embedded in a normal window; and all gesture relocations are independent `defaults` writes that one single re-login makes effective together. So the first-run experience can be *played, not read* — the user's fingers drive the real product views from the first frame, every permission is an instant visible upgrade to a scene already alive under their hand, and all system changes converge on one consent moment and one re-login.

## What Changes

- **New: the First Touch wizard** — a dedicated, chromeless Liquid-Glass first-run window, structured as acts:
  - *Overture*: brand, one line, menu-bar mark pulse — nothing asked.
  - *The Hand*: live finger dots + an embedded simulated switcher strip driven by the user's **real trackpad input** before any permission exists (scripted self-playing fallback if no touch frames flow).
  - *Make It Real*: Accessibility and Screen Recording framed as visible upgrades to the demo scene (fake cards → real windows → live thumbnails), with **live permission polling** and an **in-app relaunch helper** for the Screen Recording step.
  - *Claim the Lanes*: a trackpad-map pane where the user picks features (switcher core, Space-row switching, four-finger launcher, fixed Spaces order); one explicit consent card; one **unified relocation write**; one re-login moment ("Log out now / Later") with a **persisted pending marker**.
  - *Playground & Curtain*: dwell-to-arm taught by doing, first favorite seeded, optional features (Clipboard / AI / Keyboard Language) offered honestly, Open at Login, "Ready" seal.
  - The wizard is a **persisted state machine** that resumes correctly across both relaunches it choreographs (app relaunch for Screen Recording; re-login for relocations).
- **Removed: the four startup consent `NSAlert`s** (`didPromptNativeGesture` / `didPromptSpacesRearrange` / `didPromptVerticalGesture` / `didPromptLauncher` auto-offers) and the `showHub(selecting: .setup)` first-run fallback — replaced by the wizard gate in `AppCoordinator.start()`. Consent itself is preserved (in-wizard consent panes); completion sets the legacy flags so nothing double-fires for existing users.
- **Changed: unified gesture relocation.** When multiple relocations are consented together, final key values are computed once and pristine backups are snapshotted **before any write** — fixing the existing four-finger key collision (horizontal writes `4F-horiz=1` while the launcher needs `2`; vertical writes `4F-vert=2` while the launcher needs `0`) and the first-write-wins backup pollution. One re-login covers everything.
- **Changed: durable re-login tracking.** A persisted "relocation pending re-login" marker replaces the in-memory-only `changedThisSession` proxy, eliminating the false-positive "effective" state after an app-only relaunch.
- **Fixed: the horizontal trackpad backup becomes absent-aware** (vertical/four-finger/Spaces backups already are; horizontal currently skips absent keys on restore).
- **Changed: first-contact permission behavior.** While first-run onboarding is incomplete, a committed switch with Accessibility missing must not fire the OS prompt mid-gesture; the wizard owns first contact.
- **Changed: Hub Setup page becomes the returning-user surface** and gains a "Replay the welcome tour" entry; its permission status becomes genuinely live (polling), honoring the existing spec scenario that is not actually met today.

## Capabilities

### New Capabilities

- `first-run-onboarding`: the First Touch wizard — its window, act sequence, real-touch demo with scripted fallback, permission steps as visible upgrades with live polling and the relaunch helper, the single combined consent/apply/re-login flow, persisted resume across relaunch and re-login, completion/replay semantics, and migration for existing users (legacy `didPrompt*` flags).

### Modified Capabilities

- `permissions-onboarding`: first-run permission guidance moves from the Hub Setup page to the wizard (the "not a separate Setup/Onboarding window" clause is amended); the Setup page remains the post-onboarding surface; live status must be genuinely live (poll/refresh while visible); the Screen Recording step gains an in-app relaunch helper; the mid-gesture Accessibility prompt is suppressed while first-run onboarding is incomplete.
- `configuration-hub`: the single-window mandate is amended to carve out the transient first-run wizard window (the Hub remains the only *configuration* surface); the Setup page gains a wizard replay entry point.
- `native-gesture-config`: new requirements for the unified multi-relocation apply (final values computed once, pristine backups before any write, one re-login covers all consented relocations) and for a persisted pending-re-login state that survives app relaunch; consent scenarios are re-worded so the wizard (not a startup alert) is the consent surface; the horizontal backup becomes absent-aware.
- `spaces-rearrange-config`: the first-run consent prompt moves into the wizard's feature-selection step (consent semantics unchanged).

## Impact

- **New code**: an `Onboarding/` module in `ThreeFingerSwitcherCore` — wizard window + act views, the persisted wizard state machine, the demo drivers (sample `SwitcherModel`/`LauncherModel` data + scripted dwell driver), a touch-frame feed for the live-hand act, the self-relaunch helper, the trackpad-map consent pane.
- **`AppCoordinator`**: `start()` first-run sequence replaced by a single wizard gate; `gestureDidCommit` AX-prompt path gated on onboarding completion; new wiring context for the wizard (mirroring `HubContext`).
- **`NativeGesture/`**: unified apply path + combined pristine backup snapshot; persisted pending-re-login marker consumed by the `is…Effective` gates; `TrackpadGestureConfig` absent-aware backup fix.
- **`Permissions/PermissionsService`**: live polling while a permission surface is visible.
- **`Hub/HubSetupPage`**: replay entry; live-refresh adoption.
- **`Settings/AppSettings`**: persisted onboarding state (stage + completion), pending-relocation marker storage.
- **Tests**: wizard state-machine transitions (incl. resume-after-relaunch and resume-after-re-login), unified relocation value computation + backup snapshotting, pending-marker lifecycle, demo-model drivers — all MLX-free, verifiable under `swift test`.
- **Risk spikes**: (a) confirm touch frames flow pre-permission on a clean machine (Act I's live mode; scripted fallback de-risks); (b) confirm the wizard window can take key alongside the non-activating overlay rules (the existing `present()` dance indicates yes).
