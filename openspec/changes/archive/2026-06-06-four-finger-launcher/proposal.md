## Why

The three-finger switcher made *navigating* what already exists effortless (move between every window and Space with sub-inch swipes). The missing half is *summoning* what doesn't yet exist — opening apps, folders, scripts, shortcuts, and saved workspace states — which today still means typing, clicking Spotlight, or hunting the Dock. We want the same low-effort, eyes-optional, positional muscle-memory model pointed at "act / create": a four-finger horizontal swipe opens a launcher whose items you select by tiny travel, exactly like the window switcher. Crucially, launching an app must **open a new window in the current Space** (or pull a single-window app to you) instead of teleporting you to wherever that app already lives — the user's single most-wanted fix.

This is now cheap to build because `optional-space-row-gesture` already created the hard substrate — **runtime gesture ownership** (a session scroll tap that consumes scroll while ≥3 fingers are down, live finger-count tracking, and a crash-safe private-API synthesis pattern). Four fingers is an entirely free lane on top of it.

## What Changes

- **New four-finger launcher gesture.** A four-finger horizontal swipe past an activation threshold opens a launcher overlay; horizontal travel steps the selection through items; vertical travel (overlay open) steps between **context rows**. Mirrors the three-finger switcher's grid model and reuses its overlay infrastructure.
- **Context grid (group-by-context).** Favorites are organized into user-named, color-coded **context bands** (e.g. *Dev*, *Comms*, *Media*) — rows in the grid. Items within a band are heterogeneous and in a **fixed, user-defined order** (never MRU): the positional determinism is the product. Activation always lands on a deterministic **home cell**.
- **Heterogeneous launch items.** An item is one of: `.app`, `.path`, `.url`, `.shortcut` (Shortcuts.app), `.script` (shell / AppleScript / file), or `.preset` (an ordered composite of other items — "Work mode" / "Home mode"). Persisted as a versioned `Codable` blob.
- **"Always new window," done correctly.** Per-item app strategy with a smart default: launch-if-not-running; for multi-window-capable apps **make a new window here** by AX-pressing the app's own `File ▸ New Window` menu item; for single-window apps **bring the existing window to the current Space** via `SLSMoveWindowsToManagedSpace` (no Space teleport; the window stays where summoned). The AX menu probe doubles as the capability detector. Default strategy is inherited per context band.
- **Dwell-to-arm / lift-to-fire commit.** Unlike the switcher (lift always commits), the launcher fires only when you **dwell** on an item (configurable, ~500 ms) — signaled by a haptic tick and a visual charge-ring — *then* lift. A quick swipe-and-lift dismisses without firing; swiping off an armed item disarms it. This makes accidental, consequential commits (running a script) structurally hard.
- **The "small IDE" favorites editor.** A dedicated editor window reachable from the menu bar: a morphing sidebar that **sources items by type** (browse all apps / shortcuts / paths / presets) and a canvas that **arranges them by context band** (drag to reorder items and rows; click to remove; name, icon, and color per item and per band). Plus a menu-bar "Add front app → band" quick-add.
- **Trackpad ownership extends to four fingers.** A single launcher opt-in frees the native four-finger horizontal *and* vertical swipe gestures (`TrackpadFourFingerHorizSwipeGesture` / `TrackpadFourFingerVertSwipeGesture → 0`, one-time re-login). The existing scroll tap (predicate already `≥3` fingers) consumes the resulting four-finger scroll with no change to its rule.
- **Mission Control consolidates onto idle three-finger.** Because four-finger vertical is now claimed, the four-finger Mission Control *fallback* that `optional-space-row-gesture` left in place (`TrackpadFourFingerVertSwipeGesture = 2`) is removed; the canonical MC / App Exposé path is the app's own idle three-finger up/down synthesis (already built). No loss of Mission Control.

## Capabilities

### New Capabilities

- `launcher-overlay`: the four-finger launcher HUD — a 2D context-row × item-column grid with deterministic home-cell entry, horizontal item stepping and vertical context stepping, and a dwell-to-arm / lift-to-fire commit with haptic + charge-ring feedback. Sibling of `switcher-overlay`; reuses its grid/panel infrastructure.
- `launch-items`: the favorites data model — heterogeneous launch-item kinds (app / path / url / shortcut / script / preset) organized into named, colored context bands in a fixed user-defined order, with versioned `Codable` persistence and a deterministic home cell.
- `launch-actions`: executing a launch item — the per-item/per-context app strategy (`.smart` / always-new-window via AX menu-press / bring-existing-here via Space move / new-instance), running shortcuts and scripts, opening paths/URLs, and composing presets, with post-fire feedback for consequential items.
- `favorites-editor`: the management UI — a morphing sidebar (source by type) plus a context-band canvas (arrange by context), add / remove / reorder, per-item and per-band name / icon / color, per-band default app strategy, and a menu-bar quick-add for the front app.

### Modified Capabilities

- `gesture-recognition`: the recognizer **latches the finger count at gesture start** (3 = switcher, 4 = launcher) instead of treating a fourth finger as an unconditional cancel; for a latched four-finger gesture it emits launcher intents (activate / item-step / context-step / end). Three-finger behavior is unchanged.
- `native-gesture-config`: gains optional free/restore of the **native four-finger horizontal and vertical** swipe gestures (absent-aware backup, one-time re-login), and **removes the four-finger Mission Control fallback** previously set by `optional-space-row-gesture` (MC is now the idle three-finger synthesis).
- `runtime-gesture-ownership`: the session scroll tap's lifecycle is extended to run while the **launcher opt-in is effective** (not only the Space-row opt-in); its `≥3` consume predicate already swallows four-finger scroll unchanged.
- `tunable-settings`: gains the **launcher opt-in** (binds the four-finger feature-gate to the four-finger native-gesture free) plus launcher tunables — four-finger activation threshold, item-step distance, context-step distance, and dwell-to-arm duration.
- `menubar-app-shell`: gains a **"Favorites…"** entry that opens the editor and an **"Add front app → band"** quick-add.

## Impact

- **Builds on `optional-space-row-gesture`.** Assumes its runtime-ownership substrate (`ScrollEventTap`, `MissionControl`, live finger-count, `VerticalGestureConfig`) is present; this change extends, not replaces, it. The two share `gesture-recognition`, `native-gesture-config`, `runtime-gesture-ownership`, and `tunable-settings` deltas, which stack.
- **New code:**
  - `Overlay/LauncherModel.swift`, `Overlay/LauncherView.swift`, `Overlay/LauncherOverlayController.swift` — the grid HUD + dwell-arm/charge-ring (parallel to the `Switcher*` trio; reuses `SwitcherLayout`/panel patterns).
  - `Launcher/LaunchItem.swift` — the item/context-band model + `Codable` store (one versioned UserDefaults key).
  - `Launcher/LaunchService.swift` — dispatch: AX menu-press new window, `SLSMoveWindowsToManagedSpace` bring-here, `shortcuts`/script exec, preset composition.
  - `Launcher/HapticFeedback.swift` — `NSHapticFeedbackManager` arm tick (crash-safe / best-effort).
  - `Settings/FavoritesEditorView.swift` (+ supporting views) — the "small IDE."
  - `NativeGesture/` — extend the config to free the four-finger keys.
- **Modified code:** `Gesture/GestureRecognizer.swift` (latch count + launcher intents), `App/AppCoordinator.swift` (route launcher intents, drive the launcher overlay + dwell timer, tap-lifecycle gate, opt-in plumbing), `App/StatusItemController.swift` (Favorites / quick-add), `Settings/AppSettings.swift` + `Settings/SettingsView.swift` (opt-in + tunables), `Windows/CGSPrivate.swift` (resolve `SLSMoveWindowsToManagedSpace`).
- **System settings touched (one-time re-login):** `TrackpadFourFingerHorizSwipeGesture` and `TrackpadFourFingerVertSwipeGesture` in both trackpad domains → `0`; absent-aware backup/restore. Pinch gestures (Launchpad / Show Desktop) are untouched.
- **Permissions:** none new. Accessibility (already held) covers AX menu-press, the scroll tap, and window moves; `SLSMoveWindowsToManagedSpace` is a private symbol resolved crash-safely like the rest of `CGSPrivate`.
- **Spikes to de-risk (tracked in design):** (a) `NSHapticFeedbackManager` actuation from a background accessory app mid-gesture; (b) clean "new window here without a teleport flash" for multi-window apps; (c) `SLSMoveWindowsToManagedSpace` reliability on current macOS (Stage Manager / assigned-Space windows).
- **Tests:** recognizer finger-count latching + launcher intents; `LaunchItem` codec/round-trip + home-cell determinism; preset composition ordering; native four-finger config backup/restore (absent-aware); settings defaults/persist.
