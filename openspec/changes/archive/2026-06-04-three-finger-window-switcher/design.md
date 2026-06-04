## Context

Greenfield Swift menu-bar app replicating the Windows Precision Touchpad three-finger window switcher on macOS 15.0+ (dev machine: macOS 26 Tahoe). The defining constraint discovered during exploration: the Kyome `OpenMultitouchSupport` package wraps the **private, read-only** `MultitouchSupport.framework`. "Read-only" is the architectural keystone — we observe raw touches but never sit in the event path, so the OS always receives every touch. That means native vertical gestures (Mission Control, App Exposé) are physically impossible for us to break, and "suppressing" the native horizontal gesture is not an event-interception problem but a **configuration** problem.

The package provides per-touch `id`, normalized `position` (x,y ∈ 0..1), `pressure`, `axis`, `angle`, `density`, `state`, and `timestamp` — but **no finger count and no velocity**. Both are derived. App Sandbox must be **disabled** to load the private framework, which rules out the Mac App Store.

```
            raw trackpad touches (hardware)
                       │
        ┌──────────────┴───────────────┐
        ▼                              ▼
  WindowServer / Dock            MultitouchSupport (passive)
  (native gestures)              → OpenMultitouchSupport stream
   up   → Mission Control             → our TouchEngine
   down → App Exposé                  → GestureRecognizer
   L/R  → "full-screen app swipe"     → SwitcherController → OverlayPanel
          (turned OFF by config)      → WindowService (raise on commit)
```

## Goals / Non-Goals

**Goals:**
- Exact Windows flow: three fingers down → live horizontal scrub of a per-window highlight → lift to commit (raise + focus).
- Horizontal-only; vertical three-finger gestures remain the OS's Mission Control / App Exposé.
- Pure trackpad input — no keypresses, no clicks.
- Robust native-gesture handling without a fragile `CGEventTap`.
- Tunable sensitivity/stepping; clean permissions onboarding.

**Non-Goals:**
- Mac App Store distribution (sandbox is off).
- Replacing AltTab / a full keyboard Alt-Tab (we are gesture-only; no hotkeys in v1).
- Customizable per-app gestures, multi-monitor scrubbing semantics beyond "active screen", or window arrangement/snapping.
- Supporting trackpad-less Macs (no input device → app is inert, surfaced in UI).
- Four-finger gestures (explicitly cancel/ignore).

## Decisions

### D1 — Config-based native-gesture handling, not `CGEventTap`
"Swipe between full-screen applications" is an **independent** trackpad setting, separate from Mission Control (up) and App Exposé (down). Turning it off frees the horizontal three-finger gesture with zero conflict, and because we read passively, vertical gestures still reach the OS untouched. We toggle it via `CFPreferences`/`defaults` on the relevant trackpad domains (`com.apple.AppleMultitouchTrackpad`, `com.apple.driver.AppleBluetoothMultitouch.trackpad`, plus the symbolic-hotkey/`-AppleFn` gesture keys as needed) with user consent, persisting the prior value for restore.
- *Alternative considered*: a `CGEventTap` swallowing the native swipe only while active. Rejected — trackpad gesture events are delivered inconsistently to taps, historically brittle, and add an Input Monitoring dependency for fragile gain.
- *Trade-off*: it's a global setting, not "only while running." Mitigated by consent + restore-on-quit + clear messaging. A changed setting may require re-login or a trackpad-daemon nudge to take effect; we detect-and-warn rather than assume.

### D2 — Derive finger count and velocity from the raw stream
The stream emits `OMSTouchData` keyed by `id` with a `state` lifecycle (starting → making → touching → breaking → leaving). We maintain a dictionary `id → latest state` and define **active count** = ids in touching/making states. Velocity per finger = (positionₜ − positionₜ₋₁) / (tₜ − tₜ₁), smoothed with an EMA. The **centroid** (mean of active finger positions) drives scrub; centroid Δx is the scrub signal. Exact-three-fingers gating uses active count == 3.
- *Open*: exact stream emission semantics (one `OMSTouchData` per touch per frame vs. a batched frame) — see Open Questions / verified by a task before the recognizer is finalized.

### D3 — Scrub stepping by accumulated centroid travel with carry
Position is normalized device space (0..1), so "one window per N px" is expressed as `stepDistance` in normalized units. Maintain `accumΔx`; when `|accumΔx| ≥ stepDistance`, step index by sign and subtract `stepDistance` (keep remainder). This yields a continuous, ratcheting feel and makes reversal free (negative Δx walks the accumulator back). Clamp or wrap at list ends per setting.
- *Alternative*: velocity-threshold "flick = one step." Rejected as primary — less precise for the "one window at a time" requirement; velocity is still computed for optional acceleration/smoothing.

### D4 — Highlight live, raise only on commit
The window list is snapshotted at gesture start (frozen MRU order). During scrub we only move the highlight. Only on finger-lift do we raise + focus. This keeps scrubbing smooth and guarantees any cross-Space switch happens exactly once, at commit. Commit requires the activation threshold to have been crossed; otherwise cancel silently.

### D5 — Non-activating overlay that never steals focus
A borderless `.nonactivatingPanel` `NSPanel`, `ignoresMouseEvents = true`, high `level` (e.g. `.screenSaver`), `collectionBehavior` to appear on all Spaces and not in Mission Control, hosting a SwiftUI thumbnail strip. Non-activating is essential: the previously-focused state must be preserved so AX raise on commit targets the right window and the overlay itself is never a raise candidate.

### D6 — Window enumeration and raise stack (borrow AltTab technique)
Enumerate via `CGWindowListCopyWindowInfo` (on-screen + all Spaces) correlated to AX windows per app; filter to normal, non-minimized windows. Thumbnails via ScreenCaptureKit (`SCShareableContent` + `SCScreenshotManager.captureImage`). Raise via `AXUIElementPerformAction(window, kAXRaiseAction)` + set `kAXMainWindow`/`kAXFocusedWindow` + `NSRunningApplication.activate(.activateAllWindows)`. MRU order maintained by a focus-history tracker (NSWorkspace activation notifications + AX focused-window observers). Reusing AltTab's GPL-3 technique sets the project license to GPL-3.

### D7 — Thumbnail capture strategy: cached + lazy
Capturing N full thumbnails synchronously at gesture start risks a hitch. Strategy: maintain a small thumbnail cache refreshed opportunistically; at gesture start render cards immediately with cached image or app-icon placeholder, then fill/refresh asynchronously. Capture is the perf risk to validate (D-Risk below).

## Risks / Trade-offs

- **[Private framework drift on macOS 26]** `MultitouchSupport.framework` symbols could differ on Tahoe → Mitigation: verification task that confirms a live touch stream end-to-end on the dev machine before building the recognizer; fail loudly with a clear menu-bar error state if the stream is dead.
- **[Sandbox-off ⇒ no App Store + scarier install]** → Mitigation: notarize + clear onboarding; document why.
- **[Global setting change surprises users]** (D1 trade-off) → Mitigation: explicit consent dialog, restore-on-quit, detect-and-warn, never silently change.
- **[Setting change needs re-login to take effect]** → Mitigation: detect current effective state; if our scrub conflicts (space still switching), warn and guide rather than assume success.
- **[Thumbnail capture hitch]** (D7) → Mitigation: cache + placeholder-then-fill; cap card count; allow icon+title-only fallback if Screen Recording denied.
- **[Input Monitoring prompt uncertainty]** → Mitigation: verification task to observe whether the multitouch read triggers a TCC prompt; onboarding handles it conditionally.
- **[Cross-Space raise feels jarring]** → Mitigation: D4 confines the Space switch to a single commit moment; setting to optionally restrict to current Space can be added later.
- **[Accidental triggering during normal three-finger drag/scroll]** → Mitigation: activation threshold + axis-lock ratio + exact-three-fingers; all tunable.
- **[Focus-history MRU accuracy]** → Mitigation: fall back to z-order when history is incomplete; treat MRU as best-effort ordering.

## Migration Plan

Greenfield — no data migration. Deployment = build, notarize, distribute DMG. "Rollback" for the only stateful side effect (the trackpad setting) = restore the persisted prior value; quit/uninstall offers this. App is inert and harmless if permissions are not granted (surfaced in onboarding) or no trackpad is present.

## Open Questions

1. **Stream emission shape** — does `touchDataStream` yield one `OMSTouchData` per touch per frame, or a batched snapshot? Determines exact finger-count derivation. (Verification task.)
2. **Input Monitoring** — does reading the multitouch stream trigger a TCC Input Monitoring prompt on macOS 26? (Verification task.)
3. **Effective-state detection** — most reliable signal that "full-screen app swipe" is actually off at runtime (read-back of which preference key, and whether a daemon restart/login is required). (Verification task.)
4. **Multi-monitor** — scrub semantics when windows span displays; v1 assumes overlay on the active screen and a single global list.
