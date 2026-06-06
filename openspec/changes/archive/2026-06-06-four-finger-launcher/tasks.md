## 1. Spikes (blocking — de-risk before building the commit UX and new-window paths)

- [x] 1.1 **S-OQ1 Haptics:** From a stable-signed build (`INSTALL=1 ./scripts/build-app.sh`), verify `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime:)` actuates the Taptic Engine for a background `.accessory` app with no in-flight click. Record result; if unreliable, decide charge-ring-only and note it in design.
- [x] 1.2 **S-OQ3 Window move (symbol RESOLVED; behavioral test deferred to integration):** Confirm the exact symbol name/signature for moving a window to the current Space (`SLSMoveWindowsToManagedSpace` / `CGSMoveWindowsToManagedSpace`) on the target macOS; verify it moves a single-window app's window to the active Space WITHOUT switching Spaces, and that it stays. Test under Stage Manager and with a Space-assigned window. Capture findings.
- [x] 1.3 **S-OQ2 New window without teleport (RESOLVED):** chosen sequence = **create-then-front** — trigger the new window against the background app, then defer `activate()` until it exists (front-first teleported). Handled Terminal's submenu-parent "New Window" (press a profile leaf, ⌘N fallback) and kept submenu-parent *detection* as multi-window-capable. Captured in `design.md` (S-OQ2). `.bringExistingHere` confirmed as the per-item escape for any residual flash.
- [x] 1.4 Spike outcomes captured in `design.md`: S-OQ2 (create-then-front) and S-OQ3 (foreign-window move impossible → go-to-window / quit-reopen) resolved; S-OQ1 (haptics) decoupled as non-blocking — charge-ring is the primary arm signal, haptic is best-effort, so the dependent paths (§6 dispatch, §7 dwell-arm) ship regardless. The haptic *actuation* itself is a hardware-only check (task 1.1).
- [x] 1.5 **S-OQ4 Four-finger horizontal "off" value (discovered during apply):** the HORIZONTAL keys use a different encoding than the vertical ones (`1` == assigned to that finger count, not `2`=on/`0`=off), and `TrackpadGestureConfig` already MOVES the full-screen-app swipe onto four fingers. `FourFingerGestureConfig` writes `TrackpadFourFingerHorizSwipeGesture = 2` (reasoned "unassigned") to free it — confirm by an authoritative before/after `defaults` diff (set System Settings ▸ Trackpad ▸ "Swipe between full-screen applications" to Off, diff both trackpad domains) that `2` fully disables it rather than leaving it half-on. Update `horizFreeValue` if the diff says otherwise.

## 2. Launch-item model and persistence (`launch-items`)

- [x] 2.1 Add `Launcher/LaunchItem.swift`: `LaunchItem` (id, title, icon, tint, kind), `LaunchItemKind` enum (`.app`/`.path`/`.url`/`.shortcut`/`.script(.shell/.appleScript/.file)`/`.preset([ref])`), `ContextBand` (id, name, color, defaultAppStrategy, items), and a root `Favorites` (schemaVersion, bands, homeBandId, homeColumn) — all `Codable`.
- [x] 2.2 Add a `FavoritesStore` that persists the root under a single versioned `UserDefaults` key (constructor takes an injectable `UserDefaults`, mirroring `AppSettings` for testability), with load/save and a forward-migration hook keyed on `schemaVersion`.
- [x] 2.3 Seed sensible starter bands (Dev / Comms / Media / System) on first run, all renamable/recolorable; empty is also valid.
- [x] 2.4 Expose ordered accessors the overlay/editor consume (bands in order, items in order, resolved home cell) — never recency-sorted.

## 3. Native four-finger gesture config (`native-gesture-config`)

- [x] 3.1 Extend the native-gesture configuration to free `TrackpadFourFingerHorizSwipeGesture` and `TrackpadFourFingerVertSwipeGesture` (write disabled in both trackpad domains), with an absent-aware JSON backup — mirror `VerticalGestureConfig` exactly.
- [x] 3.2 Implement faithful restore (delete originally-absent keys, write back prior values) and `hasBackup`; restoring re-enables a prior four-finger Mission Control fallback if one existed.
- [x] 3.3 Implement `isEffectivelyFree` / `needsReloginWarning` (changed-this-session gate) so launcher emission can be gated on the change being effective.
- [x] 3.4 No-op guards: skip writes when already freed; skip restore without a backup.

## 4. Recognizer: finger-count latching + launcher intents (`gesture-recognition`)

- [x] 4.1 Latch the active finger count at `begin` (3 = switcher, 4 = launcher); use the latched count as the debounce `target`. Remove the unconditional fourth-finger cancel when the launcher opt-in is effective; preserve fourth-finger-cancels when it is off.
- [x] 4.2 Add launcher intents to the delegate protocol: `launcherDidActivate`, `launcherDidStepItem(_ dir)`, `launcherDidStepContext(_ dir)`, `launcherDidEnd`. Gate four-finger tracking on a recognizer flag set by the coordinator (`launcherEnabled`), parallel to `rowSwitchingEnabled`.
- [x] 4.3 In launcher mode: emit activate on horizontal-threshold crossing, item-steps on horizontal travel (item-step distance, with carry), context-steps on vertical travel (context-step distance, with carry), end on lift. Apply direction-reverse settings consistently. No window raise / no Space-row step in launcher mode.
- [x] 4.4 Keep three-finger behavior byte-for-byte unchanged when the gesture latches at 3.

## 5. Runtime ownership: tap lifecycle covers the launcher (`runtime-gesture-ownership`)

- [x] 5.1 Extend the scroll-tap lifecycle so it runs when the launcher opt-in is effective OR the Space-row opt-in is effective (today it gates on Space-row only). Consume predicate (`≥3`) is unchanged — it already covers four-finger scroll on both axes.
- [x] 5.2 Verify two-finger scroll still passes through and the tap stops when neither feature is effective / the switcher is disabled.

## 6. Launch actions / dispatch (`launch-actions`)

- [x] 6.1 Add `Launcher/LaunchService.swift` entry point `fire(_ item)` dispatching on kind.
- [x] 6.2 App — launch if not running (`NSWorkspace.openApplication`); first window opens on the current Space.
- [x] 6.3 App — new window via AX: walk the app's `AXMenuBar` for a `File ▸ New Window`/`New` item (ordered candidate titles + localized) and `kAXPressAction` it; the probe doubles as the multi-window capability detector. Fallback: synthesize the new-window shortcut.
- [x] 6.4 App — single-window apps: the planned "move the window to the current Space" is **impossible** for foreign windows without SIP disabled (verified on-device: `SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`, and AX minimize→restore all return success but no-op — see `design.md` D5 / S-OQ3). Pivoted: `relocate(pid:)` now only **classifies** `.broughtHere` (a window is already on the current Space → focus locally) / `.noWindows` (reopen here) / `.failed` (off-Space). On `.failed`, `LaunchService` **goes to the window** via an injected `goToWindow(pid)` closure wired to `WindowService.raise` (deliberate Space switch + Stage-Manager hold-guard). The teleport bug is fixed: we never `activate()` while a window is off-Space.
- [x] 6.5 Strategy resolution: item override → band default → `.smart` (capable ⇒ new window, else go-to-window). New opt-in `.quitAndReopenHere` (quit + relaunch → fresh window on the current Space; lossy, never chosen by `.smart`). `.newInstance` (`open -n`) only when explicitly selected.
- [x] 6.6 Path/URL (`NSWorkspace.open`), shortcut (`shortcuts run`), script (shell / AppleScript / file) execution; post-fire success/failure notification for `.script` and `.preset`.
- [x] 6.7 Preset: fire referenced items in stored order via the same dispatch; report overall success / failing step.
- [x] 6.8 Built-in actions (added during apply): `LaunchItemKind.action(SystemAction)` performed natively against the app captured at launcher-open time, no new permission. Full set across Window (minimize, zoom, toggle full screen, maximize, center, halves, quarters, close front, close all — via AX position/size + close/zoom buttons, ⌘W/⌃⌘F fallbacks), App (new window, hide, hide others, quit, force-quit — NSWorkspace), System (Mission Control/App Exposé/Show Desktop via `MissionControl`; next/prev Space, lock, screenshots via synthesized OS shortcuts; screen saver, sleep display via launch/`pmset`; empty Trash via FileManager), and Media & Display (play-pause, next, prev, volume, mute, brightness — NX system-defined keys). Grouped by category in the editor's Actions source.

## 7. Launcher overlay + dwell-arm (`launcher-overlay`)

- [x] 7.1 Add `Overlay/LauncherModel.swift` (bands grid, selectedBand/selectedColumn, armed state, charge progress) mirroring `SwitcherModel`.
- [x] 7.2 Add `Overlay/LauncherView.swift`: grid of item cells (icon + label + band tint), preset badge / script marker, colored band-indicator gutter (reuse `SwitcherLayout`), and a charge-ring overlay on the selected cell.
- [x] 7.3 Add `Overlay/LauncherOverlayController.swift`: non-activating panel (reuse `SwitcherPanel` behavior — never key/main), show on activate at the deterministic home cell, update on item/context steps.
- [x] 7.4 Dwell-to-arm timer in the controller: arm after the dwell duration of no stepping; fire haptic tick (best-effort per 1.1) + lock the charge-ring; reset/disarm on any step.
- [x] 7.5 On `launcherDidEnd` (lift): fire the armed item via `LaunchService` if armed, else dismiss; clear state.

## 8. Favorites editor (`favorites-editor`)

- [x] 8.1 Added `Settings/FavoritesEditorView.swift`: a 3-pane `HSplitView` (sources sidebar · bands column · band detail). Opened from a window hung off `AppCoordinator.showFavoritesEditor()` (mirrors `showSettings`).
- [x] 8.2 Sidebar sources by type: category index (Applications / Shortcuts / Files & Folders / URLs / Scripts / Presets) → browse list (installed apps scanned off-main; shortcuts via `shortcuts list`; paths via `NSOpenPanel`; URL/script via manual forms; presets composed from existing items) → "All sources" back button. Selecting a candidate adds it to the active target band.
- [x] 8.3 Canvas arranges by band: `.onMove` drag-reorder of bands and of items within a band, `.onDelete`/remove item, "+" create band (auto-colored), and the selected band is the active add target — all through `FavoritesStore` editor mutations.
- [x] 8.4 Manual add (url/path/script) with name + icon (Default/SF Symbol/Emoji) + tint color via a shared `AppearanceEditor`; per-item name/icon/tint and per-item window strategy; per-band name/color/default strategy. The strategy pickers surface `.quitAndReopenHere` labeled "Quit & reopen here (loses unsaved state)".
- [x] 8.5 Every edit funnels through `FavoritesStore.mutate` (persists immediately); the launcher reads `FavoritesStore.favorites` on activation so changes show next open. Covered by `FavoritesStoreEditorTests`.

## 9. Settings: opt-in + tunables (`tunable-settings`)

- [x] 9.1 Add persisted launcher opt-in (default false) to `AppSettings`, exposed so `GestureRecognizer`/`AppCoordinator` can read effective state.
- [x] 9.2 Add launcher tunables: four-finger activation threshold, item-step distance, context-step distance, dwell-to-arm duration (default ~0.5 s); persist + reset.
- [x] 9.3 Added a "Four-finger launcher" section to `SettingsView` (opt-in toggle with re-login caveat + the four tunables, disabled until the opt-in is on), and a "Four-finger launcher (optional)" GroupBox in `OnboardingView` mirroring the Space-row row (wired to `promptLauncherSetup`).

## 10. Menu-bar entry points (`menubar-app-shell`)

- [x] 10.1 "Favorites…" item in `StatusItemController` opens the editor (`showFavoritesEditor`, now a real window).
- [x] 10.2 "Add Front App to Band ▸ <band>" submenu (one item per band, or a disabled hint when none) appends `NSWorkspace.frontmostApplication` to the chosen band via `AppCoordinator.addFrontAppToBand` → `FavoritesStore`.

## 11. Coordinator wiring (lifecycle + routing)

- [x] 11.1 Observe the launcher opt-in toggle (`dropFirst`): apply/restore the four-finger native config; apply-on-launch when set; drive the effective gate that sets `recognizer.launcherEnabled`; first-run consent prompt + re-login warning (mirror `manageVerticalGesture`).
- [x] 11.2 Route launcher intents to `LauncherOverlayController` (activate/step/step-context/end); own the dwell timer interaction and the fire call.
- [x] 11.3 Extend the scroll-tap start/stop gate to include launcher-effective (per 5.1).
- [x] 11.4 Instantiate `FavoritesStore` / `LaunchService` / launcher overlay; ensure sleep/wake reset drops any in-flight launcher gesture and overlay.

## 12. Tests

- [x] 12.1 `GestureRecognizerTests`: four-finger latch routes to launcher; launcher activate/item-step/context-step/end emitted; three-finger behavior unchanged; fourth-finger still cancels when launcher off.
- [x] 12.2 `LaunchItem`/store tests: Codable round-trip across all kinds and presets; versioned key persistence; deterministic home-cell resolution; no recency reordering.
- [x] 12.3 Strategy-resolution tests (pure): item-override → band-default → `.smart`; `.newInstance` never chosen by smart. Preset ordering preserved.
- [x] 12.4 Native four-finger config tests mirroring `VerticalGestureConfigTests`: backup/restore, absent-aware delete, no-op guards (pure decision logic, no system access).
- [x] 12.5 `AppSettings` tests: launcher opt-in + tunables default/persist/reset; dwell default is ~0.5 s.

## 13. Manual verification (stable-signed build)

- [x] 13.1 Opt-in off: four fingers do nothing app-side; native four-finger gestures behave as before; three-finger switcher unchanged.
- [x] 13.2 Opt-in on (after the one-time re-login): four-finger horizontal opens the launcher at the home cell; item/context stepping works; no background scroll; pinch (Launchpad / Show Desktop) still works.
- [x] 13.3 Commit model: quick scrub-and-lift dismisses without firing; dwell arms (tick/ring) and lift fires; swipe-off disarms.
- [x] 13.4 New-window behavior: multi-window app opens a new window on the current Space (no teleport); single-window app **goes to its existing window** (or, when set to `.quitAndReopenHere`, quits + relaunches so a fresh window opens here) — never an unexpected teleport; not-running app launches here. (The original "bring the window to the current Space" is impossible for foreign windows — see design D5.)
- [x] 13.5 Editor: source-by-type sidebar adds to the active band; drag reorders items and bands; colors/icons reflect in the launcher; quick-add front app works.
- [x] 13.6 Toggle off and quit/relaunch: native four-finger gestures restored exactly and reapplied; favorites persist.
