## Why

Every launcher item today is one-shot: fire it and an effect runs once. There's no way to bind a **mode you enter and leave**. The motivating need: leave background agents running while you step away, without the Mac sleeping/locking — but with the screen dark so it's unobtrusive and low-power. That's a stateful toggle (hold a sleep/lock assertion, dim the displays, restore on stop), which no existing action kind can express.

## What Changes

- Add a new launch-item kind, **`.automation`**, and a new **Automations** source category in the Bands editor (a browsable tile alongside Actions/Apps/Scripts). Its first (v1) entry is **Keep Awake**.
- **Keep Awake** is a toggle. Firing it once **starts** the automation: snapshot each active display's brightness, set every active display to minimum, and hold a power assertion that blocks **system sleep, display sleep, and the idle screen lock** (`ProcessInfo.beginActivity`, no new permission). A ~5-minute heartbeat re-pins brightness to minimum and re-declares user activity as a safety net.
- **Stop is a trackpad touch.** After the triggering gesture fully lifts (the trackpad reports zero contacts once), the automation **arms**; the next finger-down **stops** it — restoring every display's saved brightness and releasing the assertion. The stop is non-consuming (your touch still works as a normal gesture). Arming only after the trackpad empties makes the triggering gesture unable to self-cancel.
- **Guaranteed teardown.** Stop is idempotent and also runs on app quit and on system will-sleep, so a near-black screen and a held assertion can never be stranded. A silent menu-bar **"Keep Awake — Active ✓ / Stop"** backup exists as a fire escape.

## Capabilities

### New Capabilities
- `automations`: a stateful, toggle-style launcher automation category, with **Keep Awake** as its first automation (dim all displays + block sleep/lock, heartbeat re-assert, first-touch-to-stop with guaranteed restore).

### Modified Capabilities
- `launch-items`: the item-kind model gains an `.automation(kind)` kind (backward-compatible decode; existing favorites unaffected).
- `launch-actions`: firing an `.automation` item **toggles** its automation (start if stopped, stop if running) rather than running a one-shot effect.
- `favorites-editor`: the source browser gains an **Automations** category listing the available automations, each added to the active band like any other item.

## Impact

- **Model:** new `AutomationKind` enum + `LaunchItemKind.automation(AutomationKind)`; the four exhaustive kind switches updated (`LaunchService.fire`, `LaunchItem.isConsequential`, `naturalIcon`, `kindLabel`). Optional-safe decode (no `Favorites` schema bump), covered by a test.
- **New code:** `KeepAwakeController` (MLX-free Core; owned by `AppCoordinator`) — the stateful owner with an injected effect seam so its start→arm→stop lifecycle is unit-tested deterministically; `DisplayBrightness` gains an all-active-displays helper (today it's main-display-only).
- **Wiring:** `LaunchService` gains an `onAutomation` closure (mirrors `onAICommand`); `AppCoordinator` feeds the touch stream into the controller for arming, force-stops on will-sleep, and exposes active-state + stop for the menu bar; `AppDelegate.applicationShouldTerminate` force-stops so brightness is restored before quit.
- **Permissions:** none added. `ProcessInfo.beginActivity` and the private `DisplayServices` brightness get/set both need no entitlement (sandbox-off posture).
- **Risk / caveat:** on a laptop with the lid closed, macOS forces sleep regardless of assertions (holds only lid-open or clamshell-on-power). Documented, not a bug. Brightness restore is made bulletproof (menu-bar backup + quit/sleep force-restore) because a dimmed-to-black screen makes a failed restore user-visible.
