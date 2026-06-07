## Context

The switcher overlay (`OverlayController` / `SwitcherPanel`) is a non-activating panel at `.popUpMenu` with `[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]` and **no** `.stationary`. `OverlayController.swift` documents this as deliberate: a higher level or `.stationary` "perturb the WindowServer's focus/Space arbitration." Consequently the overlay renders *below* Mission Control.

The app opens MC itself: `GestureRecognizer` emits `gestureDidTriggerMissionControl(up:)` on a fresh idle vertical swipe, and `AppCoordinator` calls `MissionControl.trigger(up:)` (`CoreDockSendNotification("com.apple.expose.awake")`, a toggle). The switcher commit path is `gestureDidCommit` → `overlay.hide()` → `windowService.raise(window)`.

## Goals / Non-Goals

**Goals:**
- Switcher fully visible above MC while MC is open.
- Selecting a window while MC is open dismisses MC and focuses that window.
- Preserve today's exact overlay behavior when MC is **not** open (no focus/Space regressions).

**Non-Goals:**
- App Exposé (separate overview).
- Detecting MC opened by something other than this app (we rely on our own trigger).

## Decisions

**D1 — Above-MC config applied only while MC is open.** `OverlayController.show(..., aboveMissionControl:)` sets, per show:
- aboveMC: `level = .screenSaver`, behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]`.
- otherwise: today's `.popUpMenu` + no `.stationary`.

Scoping the risky config to the MC-open case keeps the documented arbitration perturbation out of the 99% path; on commit we hide the overlay and dismiss MC *before* raising, so the raise runs from a clean state.

**D2 — Track MC-open state in the coordinator.** `missionControlOpen` toggles on `gestureDidTriggerMissionControl(up: true)` and is set false on App Exposé (down) and after a commit-dismiss. `gestureDidActivate` passes it as `aboveMissionControl`.

**D3 — Dismiss MC via Escape, not a re-toggle.** `MissionControl.dismiss()` synthesizes Escape (`CGEvent`, keycode 0x35) — Escape reliably closes MC and, crucially, **cannot open it** if the flag is stale (MC already closed externally). Re-sending the `com.apple.expose.awake` toggle would risk re-opening MC in that case. On commit while MC is open: hide overlay → `dismiss()` → after ~0.3s (MC close animation) → `raise(window)`.

*Alternatives considered:* (a) re-toggle to close — rejected (can reopen MC on stale state); (b) rely on `raise()` alone to dismiss MC — unreliable (activating a window doesn't consistently exit MC).

## Risks / Trade-offs

- [Higher level / `.stationary` can perturb focus/Space arbitration] → applied only while MC is open; overlay hidden + MC dismissed before the raise, which self-heals focus via its watchdog. Verify on-device that post-commit focus is correct.
- [`.screenSaver` may not be high enough above MC on some macOS versions] → if it still renders behind, bump to `CGShieldingWindowLevel()`. Verify on-device.
- [Stale `missionControlOpen` (MC closed externally)] → Escape-based dismiss makes this benign (a stray Escape to the front app, never a spurious MC open).
