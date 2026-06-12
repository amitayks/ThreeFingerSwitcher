## 1. Window focus tracker

- [x] 1.1 Add `WindowFocusTracker` (`@MainActor`) keyed by `CGWindowID`: `order: [CGWindowID]`, `promote(_:)` (move-to-front), `rank(_:) -> Int` (index or `Int.max`), mirroring `MRUTracker`'s shape.
- [x] 1.2 Add `evict(keepingLive:)` (or fold into snapshot) that prunes `order` to a given set of live window ids.
- [x] 1.3 Add a helper to resolve an application's focused window id: `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` (via `axCopy`) → `axWindowID`, returning `nil` when unresolvable.

## 2. Focus sources

- [x] 2.1 Promote on switcher commit: call `focus.promote(window.id)` inside `WindowService.raise(_:)` (`WindowService.swift:322`).
- [x] 2.2 Promote on app activation: in the tracker, observe `NSWorkspace.didActivateApplicationNotification`, resolve the new frontmost app's focused window id (task 1.3), and promote it. Seed with the current frontmost app on `start()`.
- [x] 2.3 Add a live `AXObserver` on the **frontmost app only** for `kAXFocusedWindowChangedNotification` and `kAXMainWindowChangedNotification`; on fire, resolve the focused window id and promote. Bridge the C callback via the `refcon` context pointer and bounce to the main run loop.
- [x] 2.4 Retarget the observer to the new frontmost app on each activation (remove the old run-loop source, add the new), guarded by the frontmost pid; tear down cleanly on `stop()`.
- [x] 2.5 Degrade gracefully when `AXIsProcessTrusted()` is false: skip the observer and id resolution, keep commit + activation sources, no new prompt.

## 3. Snapshot ordering

- [x] 3.1 In `WindowService.snapshot()`, before sorting, promote the current frontmost app's focused window id as the backstop (task 1.3), then evict the history to the enumerated window ids.
- [x] 3.2 Replace the primary sort key in `snapshot()` (`WindowService.swift:267`) from `appRank` to `focus.rank(wid)`; keep `onCurrent → spaceIdx → z` as the fallback for `Int.max` ranks.
- [x] 3.3 Apply the same window-rank primary key to `legacySnapshot()` (`WindowService.swift:302`).
- [x] 3.4 Extract the row comparator (or a pure `rank-then-fallback` ordering function) into a testable pure helper, mirroring how `SpaceGrouping` was extracted, so ordering is unit-testable without AppKit/AX. (New `WindowOrdering` enum.)

## 4. Wiring & lifecycle

- [x] 4.1 Construct `WindowFocusTracker` in `AppCoordinator` and inject it into `WindowService` (alongside or replacing the `mru` dependency).
- [x] 4.2 Call `focus.start()` / `focus.stop()` next to the existing `mru.start()` / `mru.stop()` (`AppCoordinator.swift:331`, `:345`), including the sleep/wake teardown path.
- [x] 4.3 Leave `MRUTracker` dormant (app-MRU no longer drives ordering) — do not delete it this change; confirm it has no remaining ordering callers. (`mru.rank` is kept only as the final `appRank` tiebreak, effectively unreachable since `z` is unique.)

## 5. Tests

- [x] 5.1 Unit-test the pure ordering helper (task 3.4): same-app windows interleave by per-window recency; never-focused windows fall back to current-Space → Space-index → z; current window first, previous second. (`WindowOrderingTests`)
- [x] 5.2 Unit-test `WindowFocusTracker`: promote/move-to-front, `rank` semantics, eviction to live ids, idempotent re-promote. (`WindowFocusTrackerTests`)
- [x] 5.3 Verify pure targets with `swift build` and `swift test`. (Both green; 685 tests, 0 failures.)

## 6. Compile verify & spec sync

- [x] 6.1 Compile-verify the AppKit/AX-bound paths (tracker, observer, `WindowService`, `AppCoordinator` wiring). All touched files live in the MLX-free `ThreeFingerSwitcherCore` target, so `swift build` compiles every AppKit/Accessibility path here — `xcodebuild` (which links MLX + downloads the Metal toolchain) is unnecessary for these Core-only changes. Verified green via `swift build`.
- [ ] 6.2 Manual check (user-run stable build): two Chromes + a Terminal — alternate Chrome↔Terminal, confirm one flick lands on the previously focused window, and an external `Cmd-\`` / click is reflected on next open.
- [x] 6.3 Verified via the implementation workflow's adversarial panel + green `swift build`/`swift test` (685 tests, 0 failures); delta synced into `openspec/specs/window-enumeration-and-raising/spec.md` on archive.
