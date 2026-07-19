# Proposal — Keep Awake: guard lock + keyboard backlight dim

## Why

Keep Awake (`add-automations-keep-awake`) leaves the Mac in a deliberately odd state: awake, **unlocked**, screen dimmed to black, background agents running. Two gaps follow from real use:

1. **Security.** Until the owner returns, *anyone* can touch the Mac and get a live, unlocked desktop — the automation blocks the idle lock by design. The stop trigger (a trackpad touch) currently just restores brightness, handing an intruder the machine.
2. **Completeness of the "dark" state.** The displays dim, but the keyboard backlight stays lit — a glowing keyboard on a "dark" Mac.

## What Changes

Two per-item, default-off options on the Keep Awake item (the `dimPercent` precedent — decode-safe optionals, no schema bump):

- **`dimKeyboard`** — the session also snapshots the keyboard backlight, sets it to zero, re-pins it on the existing heartbeat (auto-illumination fights back like auto-brightness does), and restores it on every stop path. Unavailable hardware/API is skipped, never a failure (the undimmable-display rule).
- **`lockOnStop`** (the **guard**) — once armed, **any input** stops the session and **immediately locks the screen**: trackpad contact (the existing touch stream), mouse move/click, key or modifier press (passive global event monitors — Accessibility is already granted, no new permission). The lock fires **before** brightness restore so unlocked content never flashes. The owner unlocks with Touch ID; a stranger gets only the lock screen. Any input is treated as an intentional end of the session — there is no "keep working behind the lock" phase. Only the *input* stop path locks; menu-bar stop, re-fire toggle, quit, and will-sleep teardown never lock. Input synthesized by this app itself (the computer-use agent posts CGEvents) is filtered by source PID and never trips the guard.

Internally the session generalizes to an **effects set** — symmetric state effects (display brightness, keyboard backlight: snapshot → set → re-pin → restore) plus path-sensitive exit one-shots (lock) — so "and so on" effects land as one more entry, not new machinery.

## Impact

- Affected specs: `automations` (ADDED requirements), `launch-items` (item config growth is covered by the automations delta).
- Affected code: `KeepAwakeController` (config, effects seam growth, stop reasons), new `KeyboardBrightness` + `ScreenLocker` + `InputActivityMonitor` (all MLX-free Core, crash-safe private-API resolution with fallbacks), `LaunchItem`/`LaunchService`/`AppCoordinator` plumbing, `BandsCanvas` inspector (two toggles).
- No new permission, no schema bump, no global setting (D7: the item is the opt-in). Depends on `add-automations-keep-awake` (unarchived; this stacks on it).
