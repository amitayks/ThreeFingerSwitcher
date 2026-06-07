## 1. Overlay presentation

- [x] 1.1 `OverlayController.show(...)` gains an `aboveMissionControl: Bool`; set the panel's level + collectionBehavior per show (aboveMC: `.screenSaver` + `.stationary`; else `.popUpMenu`, no `.stationary`)
- [x] 1.2 Move the level/collectionBehavior out of `makePanel` into a `configure(aboveMissionControl:)` called each show

## 2. Mission Control state + dismissal

- [x] 2.1 `MissionControl.dismiss()` — synthesize Escape (CGEvent keycode 0x35) to close MC without the open/close toggle ambiguity
- [x] 2.2 `AppCoordinator`: track `missionControlOpen` — toggle on `gestureDidTriggerMissionControl(up: true)`, set false on App Exposé (down)
- [x] 2.3 `gestureDidActivate` passes `aboveMissionControl: missionControlOpen` to `overlay.show`

## 3. Commit path

- [x] 3.1 In `gestureDidCommit`, when `missionControlOpen`: hide overlay → `MissionControl.dismiss()` → after ~0.3s raise the selected window; clear the flag
- [x] 3.2 When MC is not open, commit raises immediately as before

## 4. Verify

- [x] 4.1 `swift build` + `swift test` green
- [x] 4.2 On-device (user-run stable-signed build): open MC, trigger the switcher → cards are above MC; select a window → MC closes and that window is focused; confirm switching with MC closed is unchanged (no focus/Space regression)
- [x] 4.3 If the overlay still renders behind MC, bump the level from `.screenSaver` to `CGShieldingWindowLevel()`
