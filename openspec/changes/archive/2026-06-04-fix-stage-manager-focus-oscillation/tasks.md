## 1. Stage Manager detection

- [x] 1.1 Add `Sources/ThreeFingerSwitcher/Windows/StageManager.swift` exposing `StageManager.isEnabled`, reading `com.apple.WindowManager` `GloballyEnabled` via `CFPreferencesCopyAppValue` with `CFPreferencesAppSynchronize` first (avoid cfprefsd staleness on toggle)

## 2. Raise path gating

- [x] 2.1 In `WindowService.focusSequence`, compute `stageManagerSafe = !offSpaceHandshake && StageManager.isEnabled`
- [x] 2.2 Always run `AXUIElementPerformAction(kAXRaiseAction)`; skip the `kAXMainAttribute=true` and application `kAXFocusedWindowAttribute` writes when `stageManagerSafe`
- [x] 2.3 Keep the trailing `NSRunningApplication.activate()`, the off-Space SkyLight handshake, and the +180ms watchdog unchanged

## 3. Documentation

- [x] 3.1 Add a B3 landmine to `README.md` documenting the Stage Manager focus-war and why the singleton writes are skipped (don't re-add unconditionally)

## 4. Build & verify

- [x] 4.1 `swift build` clean; `swift test` green (117/117)
- [x] 4.2 Build + install via `./scripts/build-app.sh` (stable signature so Accessibility persists)
- [x] 4.3 Capture `process == "WindowManager"`; with a freshly reset `WindowManager`, commit repeatedly between two co-staged same-app windows and confirm no sustained ~12/sec `Model window order changed` storm (peak ≤4/sec normal activity)
- [x] 4.4 Confirm the chosen window becomes frontmost with working keyboard input, and that off-Space / Stage-Manager-off raises are unchanged
