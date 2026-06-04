## Context

`fix-focus-vacuum-on-raise` unified the raise path so that, for current-Space windows, `WindowService.focusSequence` runs `AXUIElementPerformAction(kAXRaiseAction)` → set `kAXMainAttribute=true` on the window → set the application's `kAXFocusedWindowAttribute` to that window → `NSRunningApplication.activate()`, plus a +180ms watchdog. Before that change the current-Space path was a bare `activate()`.

macOS Stage Manager is implemented by the `WindowManager` daemon. With `com.apple.WindowManager AppWindowGroupingBehavior=1` ("show windows from an application all at once"), all of an app's windows are placed on the center stage together. `kAXMainAttribute` and an application's `kAXFocusedWindowAttribute` are **per-application singletons** (one main / one focused window per app). Asserting them toward one of two co-staged windows while `activate()` re-fronts the whole group gives `WindowManager`'s stage-front arbiter and the app's AppKit two disagreeing answers, and they re-assert against each other indefinitely.

Verified empirically (log capture of `process == "WindowManager"`): committing onto two co-staged same-app windows produced sustained `Model window order changed` at ~12/sec, and the storm **continued for >10s with no ThreeFingerSwitcher process alive** (the app was killed mid-storm). So the app only *pokes* the daemon into a metastable oscillation; the loop is owned by `WindowManager`. Switching to another app, or restarting `WindowManager`, clears it. AltTab and yabai — the source of this project's raise technique — never write these per-app singletons.

## Goals / Non-Goals

**Goals:**
- A current-Space raise under Stage Manager never starts a focus war between co-staged windows.
- Preserve the focus-vacuum protection from `fix-focus-vacuum-on-raise` (watchdog + activation fallback).
- Zero behavior change when Stage Manager is off, and for off-Space (cross-Space) raises.

**Non-Goals:**
- Curing an already-stuck `WindowManager` oscillation from within the app (it is daemon-owned; the fix prevents *triggering*, not an in-flight loop).
- Changing enumeration, the gesture, the grid, thumbnails, or the off-Space SkyLight handshake.

## Decisions

### D1 — Skip the per-app focus singletons on the current-Space path when Stage Manager is enabled (the fix)
When `StageManager.isEnabled && !offSpaceHandshake`, `focusSequence` performs only `AXUIElementPerformAction(kAXRaiseAction)` (window-specific, not a per-app singleton) and `NSRunningApplication.activate()`. It skips the `kAXMainAttribute` and application `kAXFocusedWindowAttribute` writes — these are the singletons that hand the daemon a self-contradicting target. This restores the pre-vacuum-fix shape (`kAXRaise` + `activate`), which never oscillated, while keeping `kAXRaise` so the *correct* one of the two co-staged windows comes forward.

*Alternatives considered:*
- **Option A — match AltTab exactly** (`_SLPSSetFrontProcessWithOptions(0x200)` + `makeKeyWindow` byte protocol + `kAXRaise`, no `activate`, no app focused-window write) even on the current Space. Rejected as the default: it contradicts the project's existing landmine ("do not unify current-Space onto the SkyLight path — that caused the focus-vacuum regression"), so it would need re-validation against the unreproducible vacuum. Kept as a fallback if D1 ever proves insufficient for keyboard routing.
- **Full revert of `fix-focus-vacuum-on-raise`.** Rejected: it discards the watchdog + panel hardening that protect against the (rare, intermittent) focus vacuum. D1 keeps those.

### D2 — Detect Stage Manager via `com.apple.WindowManager`, re-read each raise
There is no public API. `StageManager.isEnabled` reads `GloballyEnabled` from `com.apple.WindowManager` with `CFPreferencesAppSynchronize` first (cfprefsd caches; a launch-time read goes stale after the user toggles Stage Manager). This is the community-standard method. Gate on `GloballyEnabled` (Stage Manager on at all) rather than also requiring `AppWindowGroupingBehavior==1`: the gentler raise is safe for every Stage-Manager user (it is the proven pre-vacuum-fix behavior plus the watchdog), and gating broadly also covers manually-grouped stages.

### D3 — Keep the watchdog and the off-Space path unchanged
The +180ms watchdog stays as the vacuum safety net (it is a no-op in the healthy Stage-Manager case — `frontmost matches target && app has a key window` passes immediately — so it does not re-poke the daemon). Off-Space raises keep the full SkyLight `setFront` + `makeKeyWindow` handshake.

## Risks / Trade-offs

- **[`kAXRaise` + `activate` might focus the wrong member or not route keys for some app]** → Mitigation: `kAXRaise` targets the specific chosen window; `activate()` establishes app key state; the watchdog still catches a genuine vacuum. Verified across all scenarios with no mis-focus or dead keyboard. Fallback is Option A if a specific app ever regresses.
- **[`cfprefsd` staleness]** → Mitigation: `CFPreferencesAppSynchronize` before each (cheap, once-per-commit) read.
- **[Detector gates broadly on `GloballyEnabled`]** → Acceptable: the Stage-Manager raise is the pre-vacuum-fix behavior + watchdog, strictly no worse than the prior shipped behavior for any Stage-Manager user.
- **[Cannot prove the daemon loop is impossible, only un-triggered]** → Verified by repro: with a freshly reset `WindowManager`, hammering commits between two co-staged windows produced no sustained storm (peak ≤4/sec normal activity vs ~12/sec oscillation).
