## Context

Today a three-finger **down** swipe (when the vertical opt-in is effective) synthesizes **App Exposé** via `MissionControl.trigger(up: false)` → `showAppExpose()`; when the opt-in is off, the OS owns three-finger-vertical and does App Exposé natively. Separately, the switcher's all-Spaces `snapshot()` **excludes minimized windows**: `isSwitchable` drops them as its first check (`WindowService.swift:790`, `if axBool(axWin, kAXMinimizedAttribute) { return false }`), so minimized windows are absent from the three-finger switcher and ⌘-Tab (which reuses `snapshot()`), and native Dock hover won't surface them either.

Crucially, the **Dock-preview feature already solved every hard sub-problem** for minimized windows, on a parallel path: `currentSpaceWindows(forApp:)` enumerates via `kAXWindowsAttribute` (which *includes* minimized), sets `WindowInfo.isMinimized`, orders non-minimized first (`dockPreviewOrder`), badges/dims them in the UI, guards the hover-peek (`guard !w.isMinimized`), and commits via `raiseDeminimizing` (clears `kAXMinimized`, then the hardened `raise`). The spec already carries two matching requirements: *App-scoped current-Space enumeration including minimized windows* and *Un-minimize then raise on commit of a minimized window* (the latter is generically worded). This change **generalizes that proven path into the switcher/⌘-Tab** and adds the minimize-all trigger.

All touched code is MLX-free Core (`WindowService`, `GestureRecognizer`, `SwitcherModel`, `AppCoordinator`, `AppSettings`) → verifiable with `swift build` / `swift test`; the live AX/gesture behavior needs the user's real signed build.

## Goals / Non-Goals

**Goals:**
- Three-finger **down** genuinely minimizes the current Space's windows (real `kAXMinimized`, into the Dock), revealing the desktop — Windows Win+D, not the native slide-aside.
- Minimized windows are reachable + restorable-in-place through the three-finger switcher and ⌘-Tab (Dock hover already does this).
- Reuse the Dock-preview machinery (`isMinimized`, `raiseDeminimizing`, badge/dim, peek guard, `dockPreviewOrder`) rather than inventing parallel logic.
- Opt-in, default-off, no new permission, no re-login for the reachability half.

**Non-Goals:**
- A full gesture-action **binding picker** (App Exposé / Mission Control / Show Desktop / Minimize All). Ships a focused boolean toggle; a later `gesture-bindings`-style change can generalize it.
- Native "Show Desktop" (`showDesktop()` / `com.apple.showdesktop.awake`) — explicitly rejected (see D1).
- Minimizing windows on **other** Spaces (off-Space) as part of the down-swipe — the desktop you reveal is the current Space (D2).
- Any change to the horizontal switcher activation grammar or the vertical opt-in relocation mechanics.

## Decisions

### D1 — Real minimize, not native "Show Desktop"
Set each window's `kAXMinimized` to true (the fan-out of the existing single-window `.minimizeWindow` action, `LaunchService.swift:306`). **Rejected:** `MissionControl.showDesktop()` (`com.apple.showdesktop.awake`) — it slides windows *aside* without minimizing them, is a toggle, never populates the Dock, and would leave the reachability half unexercised; it does not match "minimize all." **Rejected:** synthesizing `⌥⌘M` — app-specific (front app only), not a global minimize.

### D2 — Minimize-all targets the **current Space** only
The desktop a user reveals is the current Space; off-Space windows aren't on screen, and off-Space AX *writes* are less reliable than reads. So `minimizeAllWindows()` enumerates current-Space switchable windows (the Dock path's `currentSpaceElements` + `isSwitchable`-style gate, excluding our own app, non-standard surfaces, and already-minimized windows) and sets `kAXMinimized = true` on each. This also caps the work (bounded by current-Space window count) and sidesteps off-Space write reliability entirely.

### D3 — Reachability relaxes the gate behind the setting
`isSwitchable`'s minimized drop becomes conditional: when `includeMinimizedWindows` is on, a minimized window passes the gate and its `WindowInfo` is built with `isMinimized: true` (today the `snapshot()` path always sets it false). Non-minimized behavior is byte-for-byte unchanged when the setting is off.

### D4 — Surface minimized candidates via a supplementary per-app AX pass (the enumeration mechanism)
`snapshot()` builds its candidate set from `SpaceService.windowsInSpace(spaceID)` (the compositor's per-Space window IDs), then resolves AX elements and filters. **A minimized window may not appear in the compositor's window list at all** (it isn't composited), in which case relaxing `isSwitchable` alone would never surface it — the gate only runs on candidates that already exist. This is the one genuine unknown (see Open Questions / the spike). The robust mechanism, proven by the Dock path, is a **supplementary pass**: for each regular app, read `kAXWindowsAttribute` (includes minimized), take the minimized windows not already in the candidate set, map each AX element → `CGWindowID` (via `_AXUIElementGetWindow`), flag `isMinimized`, and merge into the snapshot. We keep the relaxed-`isSwitchable` path too, so a minimized window that *does* arrive through the compositor still passes when the setting is on (belt and suspenders). This reuses the Dock path's `currentSpaceElements` logic almost verbatim.

### D5 — Space assignment + ordering for minimized windows
A minimized window is assigned to the Space it belongs to (the current Space in the v1 current-Space scope; resolved via CGS if we extend off-Space). Within a Space-row, minimized windows sort **after** live windows, then stable by id — reusing the Dock path's `dockPreviewOrder` ordering (non-minimized first). They carry no focus recency (they're "put away"), so MRU ordering naturally keeps a short flick on live windows while minimized ones remain reachable at the tail.

### D6 — Commit reuses `raiseDeminimizing`; peek skips minimized
`AppCoordinator.gestureDidCommit` (the *shared* commit for both trackpad and ⌘-Tab) branches on `window.isMinimized`: minimized → `raiseDeminimizing(window)` (clears `kAXMinimized`, which restores the window's prior position/size automatically, then the hardened `raise` with its watchdog + hold-guard); non-minimized → `raise(window)` as today. ⌘-Tab inherits this for free. The switcher's periodic live-preview **peek must skip minimized windows** (macOS renders no fresh pixels for them) — mirror the Dock path's `guard !w.isMinimized`; minimized cards show a last-good/icon frame + badge.

### D7 — The recognizer emits a down *intent*; the coordinator picks the *action*
The recognizer already emits `gestureDidTriggerMissionControl(up:)`; keep that. The App-Exposé-vs-minimize-all choice lives in `AppCoordinator.gestureDidTriggerMissionControl` (reads `swipeDownMinimizesAll`). Minimal recognizer change; the gesture-recognition spec is reworded from "down → App Exposé" to "down → the configured down-action (default App Exposé; minimize-all when enabled)."

### D8 — Two opt-in toggles, default off, with a coupling guard
- `swipeDownMinimizesAll` (Half A) — only *effective* when the vertical opt-in is effective (else the OS owns the gesture and we never see the down-swipe).
- `includeMinimizedWindows` (Half B) — switcher/⌘-Tab reachability + de-minimize-on-commit; independent of the vertical opt-in (also helps *manually* minimized windows).

Both default **off** (every feature in this app is opt-in). **Coupling guard:** enabling `swipeDownMinimizesAll` auto-enables `includeMinimizedWindows`, and the Hub prevents turning reachability off while minimize-all is on — otherwise minimize-all would strand every window it created. The Hub groups the two under one feature block.

## Risks / Trade-offs

- **Off-Space minimized windows may not enumerate** (the compositor may omit them; off-Space AX resolution may miss them) → supplementary per-app `kAXWindowsAttribute` pass (D4); **fallback: v1 scopes reachability to current-Space minimized windows**, which is exactly where minimize-all-on-down puts them, so the core loop (down → windows appear in switcher on this Space → select restores in place) is fully satisfied. Gated by the spike.
- **Minimizing many windows = N genie animations** → user-initiated and bounded by current-Space window count; acceptable. If janky, minimize could suppress animation via a private attribute — not planned for v1.
- **Changing the down-action removes synthesized App Exposé for opted-in users** → default off; App Exposé stays the default; opting in is explicit and reversible.
- **Stranded windows if minimize-all runs with reachability off** → coupling guard auto-enables reachability (D8).
- **Stale thumbnails on minimized cards** → last-good-frame/icon + badge (existing switcher cache + Dock pattern); peek skips minimized so there are no failed live captures.
- **A minimize / de-minimize AX write fails** → follow the established error taxonomy: a failed de-minimize-on-commit is observable state (never a false "raised"); minimize-all failures never surface as an app-modal alert.

## Migration Plan

No data migration. New settings default off, so existing installs behave identically until the user opts in. Rollback = flip the toggles off (or revert the change); non-minimized enumeration and the existing App Exposé down-action are unchanged when off. **Sequencing:** land the spike first (D4 / Open Questions) to decide current-Space-only vs all-Spaces reachability before writing the enumeration code; everything else (minimize-all primitive, commit branch, badge/peek-guard, settings) is independent of the spike outcome.

## Open Questions

- **Does `SpaceService.windowsInSpace` include minimized window IDs — on the current Space? on other Spaces?** Determines whether the supplementary AX pass is strictly required and whether reachability can span Spaces. → **Spike** on the user's real build (agent can't grant TCC): enumerate a Space with a known minimized window and log whether its id appears; check `_AXUIElementGetWindow` on `kAXWindowsAttribute` minimized elements off-Space.
- **v1 reachability scope: current-Space only vs all-Spaces?** Default to **current-Space only** if the spike shows off-Space is unreliable (still satisfies the core loop); widen later if reliable.
- **Hub coupling UX:** auto-enable reachability when minimize-all is toggled on (leaning this way) vs a single grouped master toggle. Finalize during tasks.
