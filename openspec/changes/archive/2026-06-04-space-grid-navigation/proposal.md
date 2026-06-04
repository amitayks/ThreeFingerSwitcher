## Why

The cross-Space substrate now lists windows from all Spaces, but in a single flat row, and up/down does nothing. The original goal is a 2D grid: left/right scrubs windows within a Space, up/down switches which Space's row is shown. On-device testing confirmed this is feasible — once a three-finger gesture starts horizontal, macOS axis-locks the sequence and stops firing Mission Control, so up/down mid-gesture is ours to use (while a *fresh* up/down still triggers Mission Control / App Exposé).

## What Changes

- **2D gesture**: after the horizontal activation, the recognizer also tracks vertical travel. Up/down steps the selection between **Space-rows** (a separate, larger threshold with carry, so horizontal scrubbing jitter doesn't flip rows). A fresh vertical (before activation) still yields to the OS.
- **Grid model**: the snapshot is grouped by Space (in Space order, non-empty rows only); the grid starts on the current Space's row.
- **Overlay**: shows the current Space's row of cards plus a row indicator (which Space-row, how many exist); the row swap animates vertically. The adaptive width + moving highlight are preserved.
- **Commit**: lifting raises the highlighted window, switching to its Space exactly once.
- **Tunables**: `rowStepDistance` (vertical travel per row step) and `reverseVerticalDirection`.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `gesture-recognition`: adds a post-activation 2D mode where vertical travel emits Space-row steps (in addition to horizontal window steps), without claiming a fresh vertical gesture.
- `switcher-overlay`: shows the current Space-row with a row indicator and animated vertical row swaps.
- `tunable-settings`: adds vertical row-step distance and reverse-vertical-direction.

## Impact

- Code: `Gesture/GestureRecognizer.swift` (+ delegate), `Overlay/SwitcherModel.swift`, `Overlay/SwitcherView.swift`, `Overlay/OverlayController.swift`, `App/AppCoordinator.swift`, `Settings/AppSettings.swift`, `Settings/SettingsView.swift`.
- Builds on the archived `cross-space-windows` change (`WindowInfo.spaceID` / `isOnCurrentSpace`, all-Spaces `snapshot()`).
- No new permissions, dependencies, or private APIs. No change to enumeration or raising.
