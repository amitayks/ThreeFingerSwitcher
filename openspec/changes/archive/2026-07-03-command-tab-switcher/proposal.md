## Why

The cross-Space window switcher is trackpad-only: it needs three fingers and (for the vertical axis) a one-time re-login. Keyboard users live on ⌘-Tab, but macOS's ⌘-Tab is app-level, cannot preview windows, and crosses Spaces unpredictably (activating an app yanks you to wherever one of its windows happens to live). This change drives the *existing* switcher overlay — window-level, Space-aware, preview-rich — from ⌘-Tab, so keyboard users get the same switcher the trackpad gesture already opens, without a new permission or a re-login.

## What Changes

- **New opt-in (default OFF): a ⌘-Tab keyboard driver for the window switcher.** When enabled, the app intercepts ⌘-Tab via a keyboard event tap and suppresses the native macOS application switcher; when off, ⌘-Tab is untouched.
- **Hold ⌘, tap Tab → open the switcher and step FORWARD, flowing across Spaces.** Tab advances the selection through the current Space's windows in the overlay's own order (bottom-left, left-to-right, wrapping upward) and, at the end of a Space, flows into the next Space's grid — reusing the overlay's existing animated Space-row slide. Forward past the last window obeys the existing wrap/clamp setting.
- **Shift+Tab → jump back to the FIRST window (home).** A single press returns the selection to the starting window, an escape hatch when a cross-Space cycle runs long (asymmetric with forward, by design).
- **Release ⌘ → commit; Esc → cancel.** Committing raises the selected window and switches to its Space when needed, reusing the existing cross-Space raise. Cancel dismisses the overlay and raises nothing.
- **Reuse, not rebuild.** The switcher overlay, model, thumbnails, live-preview refresh, and commit/raise path are reused unchanged. Net-new is a keyboard event tap (a *driver*, sibling to the trackpad recognizer), one linear-traversal primitive on the switcher model, an opt-in setting, and mutual exclusion so the keyboard and trackpad drivers never run at once.
- No new permission (Input Monitoring is already held and tracked) and no re-login (unlike the trackpad vertical-gesture opt-in).

## Capabilities

### New Capabilities
- `command-tab-switcher`: A keyboard driver that intercepts ⌘-Tab to open and navigate the existing window switcher — Tab steps forward linearly across Spaces, Shift+Tab returns to the first window, ⌘-release commits (cross-Space raise), Esc cancels — gated behind an opt-in and mutually exclusive with the trackpad gesture.

### Modified Capabilities
<!-- None. The switcher-overlay panel, window-enumeration-and-raising (cross-Space raise), and
     gesture-recognition (trackpad) keep their existing requirements. This change adds a new
     input driver and a new traversal that drive the existing overlay; it does not change what
     the overlay renders, how windows are raised, or how the trackpad gesture behaves. -->

## Impact

- **New code (MLX-free Core, verifies under `swift build` / `swift test`):**
  - `KeyboardSwitcherTap` — a session-level `CGEventTap` on keyboard events, modeled on `TouchInput/ScrollEventTap`: watches `flagsChanged` for ⌘, swallows `Tab`/`Shift+Tab` (returns `nil`) while ⌘ is held so the OS switcher never appears, and leaves every other ⌘-key shortcut alone.
  - A pure keyboard-switcher session/state machine translating ⌘-down / Tab / Shift+Tab / ⌘-up / Esc into open / step / home / commit / cancel intents (unit-testable, no AppKit).
- **Modified:**
  - `Overlay/SwitcherModel.swift` — a linear traversal primitive (`selectLinear(delta:)` flowing across grid rows and Space-rows) and a jump-to-first, alongside the existing grid navigation.
  - `App/AppCoordinator.swift` — extract a shared `openSwitcher()` from `gestureDidActivate`; wire the keyboard driver's intents to it; enforce mutual exclusion with an in-flight trackpad gesture; mirror the wizard/demo guards.
  - `Settings/AppSettings.swift` + Hub — the opt-in flag and its toggle.
  - `ThreeFingerSwitcherApp/main.swift` — install the keyboard tap when the opt-in is on and permissions allow.
- **Reused unchanged:** `Overlay/OverlayController`, `Windows/WindowService.raise` (off-Space SkyLight handshake, already verified against AltTab), `Windows/SpaceGrouping`, the thumbnail cache and periodic refresh.
- **Permissions:** Input Monitoring (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`) is already tracked in `PermissionsService` and required by the app; no new grant. Accessibility (already held) backs the raise.
- **Load-bearing risk to spike first:** fully suppressing the native ⌘-Tab HUD from a `CGEventTap`. AltTab proves it is possible and its SkyLight bridge is already vendored here, but it is the single assumption to validate before building on it.
