## Why

macOS has no equivalent of the Windows Precision Touchpad three-finger window switcher: place three fingers down, slide left/right to scrub a live highlight across individual windows one at a time, and lift to commit to the highlighted window. The native macOS three-finger horizontal gesture is hard-wired to "swipe between full-screen applications" (space switching), not window-level switching. This change builds a lightweight menu-bar app that delivers that exact flow while leaving the native vertical gestures (Mission Control, App Exposé) fully intact.

## What Changes

- **New menu-bar app** (`LSUIElement`, App Sandbox **disabled**), distributed as a direct notarized download (not Mac App Store, because the private MultitouchSupport read requires sandbox off). Targets macOS 15.0+.
- **Passive raw-touch reading** via the Kyome `OpenMultitouchSupport` package. Because the framework is read-only, the OS still receives every touch — so up/down → Mission Control / App Exposé can never be broken by us. We derive **finger count** (from active touch ids/states) and **velocity** (from Δposition/Δt) ourselves, since the package provides neither.
- **Three-finger horizontal scrub gesture**: detect exactly three fingers → axis-lock (yield to OS if vertical dominates) → on horizontal past an activation threshold, show an overlay and step the selection ±1 every `stepDistance` of centroid travel (carry remainder for a live, ratcheting feel; reverse direction steps back) → on finger lift, **commit** (raise + focus the highlighted window) or cancel if the threshold was never crossed. A fourth finger cancels.
- **Config-based native-gesture handling (no `CGEventTap`)**: on first launch, with user consent, turn **off** "Swipe between full-screen applications" (an independent system setting) so the horizontal three-finger gesture is unclaimed. Mission Control + App Exposé stay on three fingers. Offer to restore the original value on quit/uninstall; warn if still enabled.
- **Window model**: enumerate all normal windows across all Spaces in MRU order (excluding minimized), snapshot at gesture start; only **highlight** during live scrub and only **raise on commit**, so any cross-Space switch happens exactly once.
- **Switcher overlay**: a borderless, **non-activating** `NSPanel` (ignores mouse, high window level) showing a horizontal strip of thumbnail cards (app icon + title + ScreenCaptureKit thumbnail) with a moving highlight — never steals focus, so the target window raises cleanly on commit.
- **Permissions onboarding** for Accessibility (required) + Screen Recording (required for thumbnails) + Input Monitoring (if the multitouch read prompts for it), with detection and deep-links to System Settings.
- **Tunable settings** (persisted, with a small Settings UI): activation threshold, axis-lock ratio, step distance, wrap-vs-clamp, direction, velocity smoothing, exact-three-fingers.
- **BREAKING**: modifies a user-facing system setting ("Swipe between full-screen applications") with consent; reversible.
- **Licensing**: borrowing AltTab's (GPL-3) window-raise technique makes this project **GPL-3**.

## Capabilities

### New Capabilities
- `menubar-app-shell`: `LSUIElement` app lifecycle, status-item menu, sandbox-off packaging/distribution posture, app-wide wiring of the engine and overlay.
- `touch-input`: integrate Kyome `OpenMultitouchSupport`; derive finger count and per-frame velocity from raw normalized touch data; expose a clean touch-frame stream.
- `gesture-recognition`: the three-finger horizontal scrub state machine — detection, axis-lock, activation threshold, step accumulation/carry, commit/cancel lifecycle.
- `window-enumeration-and-raising`: enumerate windows across all Spaces, maintain MRU order, capture thumbnails (ScreenCaptureKit), and raise+focus a chosen window (AX + activate).
- `switcher-overlay`: the non-activating overlay panel rendering the thumbnail strip and the live moving highlight.
- `native-gesture-config`: config-based detection/disable/restore of "Swipe between full-screen applications" with consent.
- `permissions-onboarding`: detect and guide granting Accessibility, Screen Recording, and (if needed) Input Monitoring permissions.
- `tunable-settings`: settings model, persistence, defaults, and the Settings UI for sensitivity/stepping/behavior tunables.

### Modified Capabilities
<!-- None. No existing specs in openspec/specs/; this is a greenfield project. -->

## Impact

- **New codebase**: greenfield Swift menu-bar app (Xcode/SwiftPM project, not yet present).
- **Dependencies**: Kyome `OpenMultitouchSupport` (SPM), which links the private `MultitouchSupport.framework`; ScreenCaptureKit; ApplicationServices/Accessibility; AppKit; SwiftUI.
- **System APIs**: CGWindowList, AXUIElement, NSWorkspace, `defaults`/`CFPreferences` for the trackpad setting.
- **Permissions/entitlements**: App Sandbox **off**; requires Accessibility + Screen Recording (+ possibly Input Monitoring) TCC grants.
- **Distribution**: direct notarized download only (not App Store); GPL-3 license.
- **User environment**: changes one trackpad system setting (reversible, with consent).
