## Why

Intermittently, after a few window switches, the whole system stops accepting clicks, scroll, and keyboard input — the cursor still moves and the switcher still works, and only a Mission Control swipe + reselecting a window clears it. A 5-agent research pass (high confidence; secure-input and event-taps ruled out by grep) traced this to a **focus vacuum**: `WindowService.raise()` leaves a frontmost app with **no key window**, so the WindowServer has nowhere to route pointer/keyboard/scroll events and drops them. The cursor keeps moving (drawn by the WindowServer independent of focus) and the gesture keeps working (multitouch is read passively, bypassing HID routing); Mission Control is the only action that forces focus re-arbitration. It is a race (intermittent) and predates the cross-Space code.

## What Changes

- **Deterministic raise/focus**: `raise()` now always ends with `NSRunningApplication.activate()` so AppKit establishes key state, even if the SkyLight byte protocol failed — never leaving a frontmost app without a key window. Unified for current- and off-Space: optional SkyLight front+key handshake, AX raise + main + focused-window, then activate fallback.
- **`makeKeyWindow` reports success**: checks the two `SLPSPostEventRecordTo` results and returns a Bool so the raise can fall back instead of fronting a process with no key window.
- **Overlay panel hardened**: level `.screenSaver` → `.popUpMenu`; remove `.stationary` from `collectionBehavior` (the Exposé-exempt flag that is the mechanistic link to "fixed only by Mission Control").
- **Defensive**: activate the app before modal alerts; idempotent overlay hide + hide on resignActive; reset/hide when the touch engine stops.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `window-enumeration-and-raising`: raising a window SHALL deterministically establish a key window (never leave a frontmost app without one).
- `switcher-overlay`: the overlay panel SHALL use a non-interfering window level and collection behavior, and SHALL never be left ordered-in.

## Impact

- Code: `Sources/ThreeFingerSwitcher/Windows/WindowService.swift` (raise + makeKeyWindow), `Sources/ThreeFingerSwitcher/Overlay/OverlayController.swift` (panel level/behavior, idempotent hide), `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` (activate-before-modal), `Sources/ThreeFingerSwitcher/App/AppDelegate.swift` (resignActive hide).
- No new dependencies or permissions. No spec behavior removed.
