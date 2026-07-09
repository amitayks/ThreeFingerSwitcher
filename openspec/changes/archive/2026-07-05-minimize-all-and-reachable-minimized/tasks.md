## 1. Spike & settings foundation

- [x] 1.1 **Spike (user's real build):** determine whether `SpaceService.windowsInSpace` includes minimized window IDs (current Space? other Spaces?), and whether `_AXUIElementGetWindow` resolves a `CGWindowID` for `kAXWindowsAttribute` minimized elements off-Space. → Implemented the robust superset so the feature works regardless; the spike is now a **manual verification** (steps in 7.3): current-Space minimized reachability is guaranteed by the supplementary AX pass; off-Space is the open question. No throwaway diagnostic code shipped.
- [x] 1.2 Add persisted `includeMinimizedWindows` (default `false`) to `AppSettings.swift`, with live application (next gesture, no restart).
- [x] 1.3 Add persisted `swipeDownMinimizesAll` (default `false`) to `AppSettings.swift`.
- [x] 1.4 Implement the **coupling guard** (model level): enabling `swipeDownMinimizesAll` auto-enables `includeMinimizedWindows`; block disabling `includeMinimizedWindows` while `swipeDownMinimizesAll` is on (re-entrant `didSet`); `resetToDefaults` clears the trigger first.
- [x] 1.5 Surface both toggles in the Hub Switcher page: reachability in "Behavior" (disabled while minimize-all is on), minimize-all-on-down in "Space-row switching" (disabled unless `manageVerticalGesture`).

## 2. Minimize-all on three-finger down (Half A)

- [x] 2.1 Add `WindowService.minimizeAllWindows()` — enumerate **current-Space** windows via `kAXWindowsAttribute`, skip already-minimized, gate with `isSwitchable` (own app / floating / non-standard excluded), set `kAXMinimized = true` on each. Idempotent; one failure doesn't block the rest.
- [x] 2.2 Return `(minimized, failed)` counts as observable state (no silent success, no `NSAlert`).
- [x] 2.3 In `AppCoordinator.gestureDidTriggerMissionControl(up:)`, dispatch the **down** branch to `minimizeAllWindows()` when `swipeDownMinimizesAll`, else `MissionControl.trigger(up: false)` (App Exposé). Up branch unchanged.
- [x] 2.4 Recognizer still emits the same one-shot down intent regardless of action (no `GestureRecognizer` logic change).

## 3. Minimized windows reachable in the switcher (Half B — enumeration & commit)

- [x] 3.1 `isSwitchable`'s minimized drop is conditional on `includeMinimizedWindows`; other gates (non-standard, layer-0) intact and independent.
- [x] 3.2 `snapshot()` main loop sets `WindowInfo.isMinimized` (gated read so the setting-off hot path is unchanged).
- [x] 3.3 Supplementary per-app `kAXWindowsAttribute` pass appends current-Space minimized windows the CGS candidate set missed (deduped, stable id order, element cached for commit).
- [x] 3.4 Minimized windows sort **after** live within a Space-row — added `isMinimized` to `WindowOrdering.Key` (defaulted for source-compat) + the supplementary pass appends last.
- [x] 3.5 Reachability scoped so widening off-Space is a one-line change (the supplementary pass is current-Space; main-loop relaxation covers any CGS-listed off-Space minimized).
- [x] 3.6 Shared `AppCoordinator.gestureDidCommit` routes through `raiseCommitted` → `raiseDeminimizing` for minimized, `raise` otherwise. ⌘-Tab inherits it.

## 4. Switcher UI: badge & peek guard

- [x] 4.1 `SwitcherView.card` shows a "Minimized" badge + dims a non-selected minimized card (Dock-preview parity).
- [x] 4.2 `ThumbnailService.prefetch` skips minimized windows (no fresh pixels); they keep their seeded cached/icon frame.
- [x] 4.3 Live (non-minimized) cards capture/refresh unchanged (the filter only removes minimized; the two safety gates untouched).

## 5. ⌘-Tab parity

- [x] 5.1 Minimized windows appear in the ⌘-Tab reel (shared `snapshot()`) and releasing ⌘ un-minimizes-then-raises (shared `gestureDidCommit` → `raiseCommitted`). Inheritance holds by construction — no ⌘-Tab-specific code.

## 6. Tests (pure Core, `swift test`)

- [x] 6.1 `minimizeAllWindows()` gate — **AX-bound, no pure seam in this harness** (uses live `AXUIElementCreateApplication` / `NSWorkspace`, consistent with the rest of `WindowService`'s AX methods, none of which are unit-tested). Validated by run-verify (7.3).
- [x] 6.2 `isSwitchable` / snapshot inclusion — **AX-bound** (private + live AX). Validated by run-verify (7.3); the ordering consequence is covered by 6.3 and the settings gating by 6.5.
- [x] 6.3 Ordering: minimized windows sort after live within a Space-row (`WindowOrderingTests` — 2 new pure tests, passing).
- [x] 6.4 Commit branch (`raiseCommitted`) — **coordinator-bound** (trivial `if isMinimized` inside the non-instantiable `AppCoordinator`). Validated by run-verify (7.3).
- [x] 6.5 Settings coupling guard, defaults, reset, persistence (`AppSettingsTests` — 7 new pure tests, passing).
- [x] 6.6 Down-action dispatch — **coordinator-bound** (in `AppCoordinator.gestureDidTriggerMissionControl`). Validated by run-verify (7.3); the recognizer's unchanged intent emission is covered by existing `GestureRecognizerTests`.

## 7. Verify & hand off

- [x] 7.1 `swift build` and `swift test` green (MLX-free Core) — 1490 tests, 0 failures. Did NOT assemble/install the `.app`.
- [x] 7.2 Full package graph (incl. MLX-linked `GemmaRuntime`) compiles via `swift build`; no MLX touch points in this change.
- [x] 7.3 Handed off to the user for run-verify on their stable-signed build (`INSTALL=1 ./scripts/build-app.sh`): three-finger-down minimizes all & reveals desktop; minimized windows appear/badged in switcher + ⌘-Tab; selecting restores in place; the spike question (1.1) confirmed on real hardware. (Verification steps delivered; hardware run is the user's step.)
- [x] 7.4 Update `CLAUDE.md` landmines: current-Space real minimize (not `showDesktop()`); coupling guard; peek skips minimized; the CGS-omits-minimized superset + off-Space scope.
