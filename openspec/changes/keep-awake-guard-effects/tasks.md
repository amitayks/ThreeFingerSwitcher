# Tasks — keep-awake-guard-effects

## 1. Item model + seam
- [x] 1.1 `LaunchItemKind.automation` grows `dimKeyboard: Bool? = nil, lockOnStop: Bool? = nil` (decode-safe optionals, no schema bump)
- [x] 1.2 `AutomationSettings` resolved-config struct; `LaunchService.onAutomation` becomes `(AutomationKind, AutomationSettings)`
- [x] 1.3 `AppCoordinator.onAutomation` builds `KeepAwakeController.Config` and toggles with it

## 2. New Core surfaces (crash-safe private API)
- [x] 2.1 `KeyboardBrightness` — CoreBrightness `KeyboardBrightnessClient` via dlopen + responds(to:)-guarded IMP casts; IDs/get/set, unavailable → empty/nil
- [x] 2.2 `ScreenLocker` — `SACLockScreenImmediate` via dlsym; ⌃⌘Q CGEvent fallback
- [x] 2.3 `InputActivityMonitor` — passive global+local NSEvent monitors (mouseMoved, mouse downs, keyDown, flagsChanged); excludes scrollWheel; filters self-PID synthetic events

## 3. Controller
- [x] 3.1 `Config` (dimLevel, dimKeyboard, lockOnStop); `start(_:)`/`toggle(_:)`; conveniences preserved
- [x] 3.2 Keyboard snapshot/zero on start, heartbeat re-pin, restore on stop (skip-unreadable)
- [x] 3.3 `StopReason` (.input/.explicit); lock only on `.input` + guard; ordering: monitors off → lock → restore keyboard → restore displays → end assertion
- [x] 3.4 Guard monitors installed on ARM only when guarded; removed first in stop; touch stop passes `.input`
- [x] 3.5 Effects seam grows (keyboard IDs/get/set, lockScreen, begin/endInputMonitoring) with test-friendly defaults

## 4. UI
- [x] 4.1 `BandsCanvas` automation inspector: keyboard + guard toggles with captions; inspector height bump

## 5. Tests (`swift test`)
- [x] 5.1 Keyboard effect: dims/snapshots on start, heartbeat re-pins, every stop path restores, off → untouched, unreadable skipped
- [x] 5.2 Guard: monitors installed only at ARM when guarded; monitor input and touch both stop+lock exactly once; lock ordered before restore; explicit stop never locks; guard off → no monitors, no lock; idempotent double-stop ends monitors once
- [x] 5.3 Codable: new fields round-trip; legacy `.automation` JSON (kind-only and kind+dimPercent) decodes to nil options

## 6. Verify
- [x] 6.1 `swift build` + `swift test` green (Core, MLX-free)
- [ ] 6.2 User-run verification in a stable-signed build: real backlight dim/restore, real lock on each input kind, agent-synthetic-input immunity (runtime unknown: `KeyboardBrightnessClient` selectors)
