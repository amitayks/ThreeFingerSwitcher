## Why

The four-finger launcher's favorites section has accumulated behavioral bugs that only surface on-device (the effect paths are not unit-tested). This is a **rolling change**: it stays open and gathers fixes for distinct favorites-section bugs as they are found, each captured as its own spec delta + tasks so the change reads as a changelog of corrections rather than one monolithic edit.

**Bug #1 — "Go to its window" fails silently for a running, windowless app.** When an app item uses the `bring-existing-here` ("Go to its window") strategy — or `smart` falls back to it for a single-window app — and the app is *running in the background with no open windows*, firing it does nothing visible. The app comes to the foreground but no window appears. It only works when the app is fully quit (which takes the launch path instead). This hits every single-window app left running windowless (Xcode, Preview, etc.).

Root cause: the `.noWindows` branch of `bringExistingHere` calls `NSRunningApplication.activate()`, which only fronts the process — it does not send the `applicationShouldHandleReopen` event that makes an app recreate a window. Only `NSWorkspace.openApplication` / a Dock click (the path the *not-running* case already uses) triggers reopen.

## What Changes

- **Bug #1:** Treat "running but windowless" the same as "not running" — reopen the app via `NSWorkspace.openApplication` (Dock-click equivalent, fires reopen) so a fresh window opens on the current Space, instead of a no-op `activate()`. No teleport risk, since there is no off-Space window to front.
- Tighten the `launch-actions` spec to state the windowless-running behavior explicitly (today the requirement only addresses windows that are on the current/other Space, leaving "no windows anywhere" underspecified).
- (Rolling) Future favorites-section bugs append new spec deltas and task sections under this same change.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `launch-actions`: (Bug #1/#2) the single-window-strategy requirement gains an explicit clause for a running app with no windows anywhere — reopen via the workspace, escalating to a new-window command; (Bug #3) a new requirement that arrow-key system shortcuts (Next/Previous Space) are synthesized faithfully; (Bug #4) a new requirement that Space-switch actions leave the destination's front window focused.
- `launcher-overlay`: (Bug #5) the "Lift fires only when armed" requirement gains a hide-before-fire ordering so a Space-switching action does not drag the all-Spaces overlay onto the destination Space.

## Impact

- **Code:** `Sources/ThreeFingerSwitcher/Launcher/LaunchService.swift` — `bringExistingHere(_:)` (`.noWindows` branch) and its caller `fireApp(_:strategy:)` (thread the bundle URL through so the reopen has a target). No change to `SpaceWindowMover` classification.
- **Behavior:** `bring-existing-here` and `smart` (single-window fallback) now produce a window for a running, windowless app instead of failing silently. No change to the on-Space-focus or off-Space go-to-window paths.
- **Tests:** effect path remains on-device-verified; no logic-test changes required for Bug #1.
- **Permissions:** none (uses existing NSWorkspace; no new entitlement).
