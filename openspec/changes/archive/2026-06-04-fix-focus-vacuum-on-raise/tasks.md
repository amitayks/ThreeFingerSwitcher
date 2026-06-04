## 1. Deterministic raise (primary)

- [x] 1.1 `WindowService.makeKeyWindow(_:_:)`: check both `SLPSPostEventRecordTo` return values; return `Bool` (true only if both succeed).
- [x] 1.2 `WindowService.raise(_:)`: unify into one sequence that always ends with `NSRunningApplication(pid)?.activate()` — (a) optional SkyLight handshake (`GetProcessForPID` reject-zero-PSN → `setFront(0x200)` → `makeKeyWindow`), (b) AX `kAXRaiseAction` + `kAXMainAttribute` + app `kAXFocusedWindowAttribute` when an element resolved, (c) always `activate()`. Remove the off-Space early return; keep element re-resolution at commit.

## 2. Overlay panel (primary)

- [x] 2.1 `OverlayController.makePanel()`: `level = .popUpMenu` (was `.screenSaver`); `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]` (drop `.stationary`).

## 3. Defensive teardown + modal hygiene

- [x] 3.1 `OverlayController.hide()` idempotent; add a `hideOnResignActive` hook.
- [x] 3.2 `AppDelegate`: hide the overlay on `applicationWillResignActive` / `NSApplication.didResignActiveNotification`.
- [x] 3.3 `AppCoordinator`: call `NSApp.activate(ignoringOtherApps: true)` before each `NSAlert.runModal()` (promptNativeGestureSetup, offerRestoreOnQuit, restoreNativeGestureSetting, infoAlert).
- [x] 3.4 Ensure `recognizer.reset()` runs when the touch engine stops (so a stalled stream can't leave the panel up).

## 4. Build & verify

- [x] 4.1 `swift build` clean; assemble bundle.
- [x] 4.2 On-device: rapidly commit dozens of window switches across current- and off-Space targets; confirm clicks/scroll/keyboard keep working after every commit with no Mission-Control rescue.
- [ ] 4.3 (Optional) env-gated logging: confirm a non-nil `kAXFocusedWindow` on the now-front app after each raise, and `IsSecureEventInputEnabled()` stays false.
