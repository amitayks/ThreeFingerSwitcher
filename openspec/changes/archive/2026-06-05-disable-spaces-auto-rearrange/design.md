## Context

The `stable-space-row-order` change orders the switcher's Space-rows by the live Mission Control order from `CGSCopyManagedDisplaySpaces` (`SpaceModel.indexBySpace`). macOS's "Automatically rearrange Spaces based on most recent use" (System Settings ▸ Desktop & Dock ▸ Mission Control) reorders that sequence as the user navigates, so the switcher's order — faithfully mirroring Mission Control — drifts right back into instability. The setting is the `com.apple.dock` preference key `mru-spaces` (boolean); it defaults to ON and is usually *absent* until changed.

The app already manages a sibling system setting: `NativeGesture/TrackpadGestureConfig.swift` reads/writes a system `defaults` domain via `/usr/bin/defaults`, backs the prior value up to `UserDefaults` as JSON, restores on demand, and is wired into onboarding consent (`AppCoordinator.maybePromptNativeGestureSetup`) and quit-time restore (`offerRestoreOnQuit`). This change adds a near-twin for `mru-spaces`.

The app is **unsandboxed** (App Sandbox is off — it loads a private framework), so it may write `com.apple.dock` and run `killall Dock` without entitlements or TCC prompts.

## Goals / Non-Goals

**Goals:**
- With consent, disable Spaces auto-rearrange so Mission Control — and thus the switcher — keeps a fixed Space order.
- Manage the setting around the app's lifetime: apply on launch, restore on quit, reapply on relaunch (changed only while the app runs).
- Restore the system to its *exact* prior state, including the common "key absent (default)" case.
- Reuse the proven `TrackpadGestureConfig` seam; keep the switcher's order matching what the user sees in Mission Control.

**Non-Goals:**
- No app-side "stable ordinal" scheme that diverges from Mission Control order (rejected — see Decisions).
- No silent system change without consent.
- No cross-Mac sync (each Mac is configured independently when the user opts in).
- No change to gesture recognition, raising/focus, or the overlay.

## Decisions

### Change the OS setting (Option A), not an app-side ordinal (Option B)
Disabling `mru-spaces` makes Mission Control itself stable, so the switcher's order is stable *and still matches what the user sees in Mission Control*. The alternative — keeping our own first-seen ordinal per Space id and ignoring the live index — would stay stable even with `mru-spaces` on, but the switcher's "Space 2" would no longer match Mission Control's "Space 2", trading one inconsistency for another and breaking the core premise of `stable-space-row-order`. Option A is also the one that reuses the existing pattern.

### New `SpacesRearrangeConfig`, modeled on `TrackpadGestureConfig`
Reuse the `/usr/bin/defaults` shell-helper approach (reliable for system-managed domains) and the `UserDefaults` JSON backup. Differences from the trackpad config:
- **Apply needs a Dock restart.** `defaults write com.apple.dock mru-spaces -bool false` only takes effect after `killall Dock` (Mission Control lives in Dock). The restart is ~1s and loses no Spaces/windows/focus. The trackpad setting instead needs a re-login; this one is instant.
- **Absent-key-aware backup/restore.** Because `mru-spaces` is usually absent (default ON), the backup must record one of `{absent, true, false}`. Restore deletes the key when the prior state was absent, and writes the value otherwise — so we never leave a lingering explicit `true` that differs from the original default.

### Lifecycle: active only while the app runs
A persisted opt-in flag (`AppSettings.manageSpacesRearrange`) records consent. When it is on:
- **Launch:** if `mru-spaces` is not already `false`, back up the current state, write `false`, `killall Dock`.
- **Quit:** if the app changed it this session, restore the backed-up state and `killall Dock`.
- **Relaunch:** the launch step reapplies.

To avoid gratuitous Dock restarts, each mutate is gated on the value actually needing to change. Given restore-on-quit reverts to the default, a normal session still incurs one Dock restart at launch and one at quit while the feature is enabled — an accepted consequence of the "active only while running" model the user chose.

### Consent and surfaces
First-run consent mirrors `maybePromptNativeGestureSetup` (prompt once, persist that we asked). Onboarding shows a status row (auto-rearrange on/off) like the "Native gesture" GroupBox; Settings exposes a persistent toggle bound to `manageSpacesRearrange`.

## Risks / Trade-offs

- **Dock-restart flash at launch/quit while enabled** → inherent to the active-while-running model. Mitigation: only restart when the value actually changes; the launch restart often coincides with login (Dock starting anyway). Open question: skip the quit-time `killall` and let restore apply lazily at next Dock restart (no quit flash, but auto-rearrange doesn't resume until then).
- **Crash / force-kill skips restore-on-quit** → the setting is left at `false` with the backup still in `UserDefaults`; the next launch can still restore it, but an uninstall-after-crash leaves the system changed. Mitigation: document; consider a restore step in any uninstall helper.
- **System-global change** → disabling auto-rearrange affects Mission Control for every app, not just ours. Mitigation: consent copy must state this; restore-on-quit limits the blast radius to app-running time.
- **Managed / MDM-locked preference** → the write or Dock restart may not stick. Mitigation: the mutate helpers return success/failure (as `TrackpadGestureConfig` already does); surface a non-fatal warning instead of assuming success.
- **Quit-time restore must complete before exit** → run the restore + `killall Dock` synchronously in the termination path (`applicationWillTerminate` / quit handler), waiting for the helper to finish, so the app doesn't exit mid-restore.
