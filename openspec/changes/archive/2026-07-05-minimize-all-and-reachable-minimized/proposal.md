## Why

macOS makes minimized windows second-class: a minimized window vanishes from every fast switch surface — it is gone from the three-finger switcher and ⌘-Tab, and native Dock hover won't surface it — recoverable only by right-clicking the Dock icon and picking it from a menu. Windows (the OS) gets this right: minimize sends a window to the taskbar but it stays reachable via Alt+Tab / taskbar hover, and selecting it restores it in place. This change brings that model to the app: a three-finger **down** swipe **truly minimizes every window** to reveal the desktop (Windows "Show Desktop" / Win+D), and — so those windows aren't stranded — **minimized windows become first-class in the switcher and ⌘-Tab**, restored in place when selected. The two halves are one feature: minimize-all is only usable if you can pull the windows back.

## What Changes

- **Three-finger down = minimize all windows (opt-in).** When enabled, an idle three-finger **down** swipe genuinely minimizes every switchable window (sets each window's Accessibility minimized state), clearing the desktop into the Dock — instead of synthesizing App Exposé. This is a *real* minimize, not the native "Show Desktop" slide-aside and not a toggle. It only fires for users who have the vertical opt-in effective (Space-row switching enabled + re-login), since otherwise the OS owns three-finger-vertical. App Exposé remains the default down-action when the opt-in is off.
- **New minimize-all primitive.** A `WindowService` operation that enumerates the switchable windows (same gate as the switcher, excluding our own app and non-standard surfaces) and minimizes each — the fan-out counterpart of the existing single-window minimize.
- **Minimized windows appear in the switcher and ⌘-Tab (opt-in).** The all-Spaces `snapshot()` optionally includes minimized windows, each flagged and rendered with a "minimized" badge (reusing the Dock-preview treatment). Committing a minimized window **un-minimizes it in place then raises it** — the existing `raiseDeminimizing` path already does exactly this; restoring the window's prior position/size is automatic.
- **Hover-peek guarded for minimized windows.** The switcher's live-preview peek skips minimized windows (they can't render fresh pixels), mirroring the Dock-preview guard; they show a last-good/icon frame and surface live only on commit.
- **Dock hover already covered.** The opt-in Dock-preview feature already includes, badges, and de-minimizes minimized windows — noted for parity; no work there.
- **Coupling guard.** Enabling minimize-all-on-down implies minimized-reachability so windows are never stranded (the Hub surfaces the two together).
- No new permission, no gesture relocation beyond the existing vertical opt-in, no re-login for the reachability half.

## Capabilities

### New Capabilities

<!-- None. Every behavior extends an existing capability; the machinery for minimized windows (flagging, de-minimize-on-commit) already exists for the Dock-preview path and is generalized here. -->

### Modified Capabilities

- `gesture-recognition`: the fresh idle three-finger-**down** intent maps to a **configured down-action** — App Exposé by default, or minimize-all-and-reveal-desktop when the opt-in is on — rather than always App Exposé.
- `window-enumeration-and-raising`: the all-Spaces `snapshot()` gate optionally **includes minimized windows** (flagged) instead of always excluding them; a new **minimize-all-windows** operation is added; the existing un-minimize-then-raise-on-commit requirement now also governs switcher/⌘-Tab commits (the Dock path's "switcher enumeration is unchanged" note is relaxed).
- `switcher-overlay`: minimized windows are **rendered with a minimized badge/dim** and the live-preview **peek skips** them; selecting one restores it in place.
- `command-tab-switcher`: minimized windows are reachable in the ⌘-Tab reel and **releasing ⌘ un-minimizes then raises** a minimized selection.
- `tunable-settings`: new persisted opt-in settings for minimize-all-on-down and minimized-window reachability, defaulting to today's behavior (both off).

## Impact

- **Code (all MLX-free Core; verify with `swift build` / `swift test`):**
  - `Windows/WindowService.swift`: relax `isSwitchable` (behind the setting) to admit minimized windows and set `WindowInfo.isMinimized` on the `snapshot()` path; add a `minimizeAllWindows()` operation; possibly a supplementary AX pass if the compositor does not enumerate off-Space minimized windows (see design — the one open unknown, gated by a spike).
  - `Gesture/GestureRecognizer.swift` + `App/AppCoordinator.swift`: the `gestureDidTriggerMissionControl(up: false)` down branch dispatches the configured down-action (minimize-all vs App Exposé).
  - `Overlay/SwitcherView.swift` / `SwitcherModel.swift`: minimized badge/dim (reuse the `DockPreviewOverlay` pattern); guard the hover-peek; `AppCoordinator.gestureDidCommit` branches to `raiseDeminimizing` for minimized selections (⌘-Tab inherits this shared commit).
  - `Settings/AppSettings.swift`: new persisted toggles; Hub surfacing groups them with the coupling guard.
- **Reuse, not rebuild:** `WindowInfo.isMinimized`, `raiseDeminimizing`, the Dock-preview minimized badge UI, and the single-window minimize AX write all already exist.
- **Errors:** any minimize/de-minimize failure follows the established taxonomy — observable state, never a silent false success, never an app-modal alert.
- **Out of scope:** a full gesture-action binding picker (App Exposé / Mission Control / Show Desktop / Minimize All) — this ships a focused toggle that a later `gesture-bindings`-style change can generalize; no changes to the horizontal switcher activation grammar or the vertical opt-in relocation mechanics.
