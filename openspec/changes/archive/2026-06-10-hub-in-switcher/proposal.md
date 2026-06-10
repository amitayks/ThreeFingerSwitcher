## Why

The app is an accessory (`LSUIElement`) app: no Dock icon, no Cmd-Tab entry. That is by design — but it also means the configuration **Hub** window has no system-level switcher entry, and the app's own three-finger window switcher deliberately excludes our PID (so the non-activating overlay panels never leak into the strip). The combined effect: once the Hub is open and the user scrubs away to another window, there is **no gesture path back to the Hub**. The user wants the Hub — and only the Hub — to be reachable from the switcher while it is open, without giving up accessory mode.

## What Changes

- **NEW: the configuration Hub appears as a switcher card while it is open.** When a three-finger switch starts and the Hub window is visible, the snapshot gains a single **synthetic** entry for the Hub. Committing that card focuses the real Hub window.
- **Only the Hub is injected.** The general self-PID filter in `WindowService.snapshot()` is **unchanged** (relaxing it would leak the overlay panels). The Hub entry is added on purpose, exactly once, only when `hubWindow.isVisible`.
- **Icon-only card, no thumbnail.** The Hub card carries no AX element and no captured thumbnail; the switcher renders the app icon (its existing no-thumbnail fallback). The Hub's window id is excluded from thumbnail seed/prefetch so **no ScreenCaptureKit self-capture is attempted**.
- **The Hub stays on the Space it was opened on.** The Hub window does NOT join all Spaces (`.canJoinAllSpaces`/`.moveToActiveSpace` are not added). The synthetic entry is placed on the Hub's opened Space-row; committing it focuses the Hub, switching to its Space if it is elsewhere — the same as raising any off-Space window.
- **Accessory mode is preserved.** No `setActivationPolicy` call anywhere; the app keeps no Dock icon and no Cmd-Tab entry. Focusing our own window is reliable in accessory mode via `NSApp.activate(ignoringOtherApps:)` + `makeKeyAndOrderFront` (the existing `present(_:)` path).

## Capabilities

### Modified Capabilities
- `switcher-overlay`: while the Hub is open, the switcher includes a single synthetic, icon-only Hub card placed on the Hub's opened Space-row; only the Hub is injected (the overlay panels stay excluded); committing it focuses the real Hub window; accessory mode is preserved.

## Impact

- **New file:** `Sources/ThreeFingerSwitcher/Windows/HubSwitcherEntry.swift` — a pure, testable builder for the synthetic Hub `WindowInfo` (with Space placement) and the "is this the Hub id" commit decision.
- **Modified:** `AppCoordinator` — capture the Hub's Space in `showHub`; inject the Hub entry in `gestureDidActivate`; recognize and `present` the Hub in `gestureDidCommit`; exclude the Hub id from `prefetchCurrentRow`'s thumbnail seed/prefetch.
- **Tests:** `Tests/ThreeFingerSwitcherTests/HubSwitcherEntryTests.swift` — inclusion gate (visible-only), synthetic fields/title/icon, Space placement (co-resident copy / Hub-Space fallback / current-Space fallback), the commit decision, and end-to-end grouping into the right Space-row via `SpaceGrouping`.
- **Verification:** `swift build` / `swift test` (MLX-free Core + tests); `xcodebuild` compile-verify for the MLX-linked app target. No agent-shell app build/sign/install.
