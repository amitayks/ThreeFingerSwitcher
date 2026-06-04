## Why

The `fix-focus-vacuum-on-raise` change added per-application AX focus-singleton writes (`kAXMainAttribute` + the app's `kAXFocusedWindowAttribute`) to the current-Space raise path. Under macOS **Stage Manager** with app-window grouping (`com.apple.WindowManager AppWindowGroupingBehavior=1`), two windows of one app share the center stage; pointing those per-app singletons at one of them hands the `WindowManager` daemon a self-contradicting target and it ping-pongs focus between the two windows ~12×/sec. The loop lives inside `WindowManager`, so it is **self-sustaining and survives the app quitting** (verified by log capture: the WindowServer kept reordering ~12/sec for >10s with no app process alive). It only stops when the user switches to another app or `WindowManager` is restarted. This is a regression that did not occur before that change.

## What Changes

- When **Stage Manager is enabled** and a raise targets a **current-Space** window, `WindowService.focusSequence` raises the chosen window with `AXUIElementPerformAction(kAXRaiseAction)` + `NSRunningApplication.activate()` **only**, and **skips** the per-app `kAXMainAttribute` and `kAXFocusedWindowAttribute` writes that cause the oscillation.
- Add a `StageManager` detector that reads `com.apple.WindowManager`'s `GloballyEnabled` (synchronized each read to avoid a stale `cfprefsd` value after the user toggles Stage Manager).
- **Unchanged:** off-Space raises keep the full SkyLight `_SLPSSetFrontProcessWithOptions` + `makeKeyWindow` handshake; the +180ms focus-vacuum watchdog stays as the safety net; when Stage Manager is **off**, the raise path is byte-for-byte identical to today (zero behavior change for non-Stage-Manager users).

## Capabilities

### New Capabilities
<!-- None. StageManager detection is an implementation detail of the raise behavior below. -->

### Modified Capabilities
- `window-enumeration-and-raising`: raising a current-Space window SHALL NOT leave macOS in a sustained focus-oscillation between co-staged windows when Stage Manager is enabled; under Stage Manager the raise SHALL avoid asserting per-application focus singletons while still establishing the chosen window as frontmost.

## Impact

- Code: `Sources/ThreeFingerSwitcher/Windows/StageManager.swift` (new detector), `Sources/ThreeFingerSwitcher/Windows/WindowService.swift` (`focusSequence` gating). `README.md` B3 landmine updated.
- No new dependencies, permissions, or spec capabilities removed. No change to enumeration, the gesture, the grid, or the off-Space cross-Space raise.
