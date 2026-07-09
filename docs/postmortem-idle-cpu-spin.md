# Postmortem — idle main-thread CPU spin ("switcher slow after a break")

## Summary

Intermittently — typically after the Mac had been idle/asleep overnight — the three-finger
switcher became very slow to respond, and an app restart fixed it for days. The cause was **not**
in the gesture pipeline. The app was pinning its **main thread at ~100% CPU** in a
SwiftUI ⇄ AppKit Auto-Layout ⇄ Observation feedback loop, driven by perpetual
`TimelineView(.periodic)` "breathing"/autoplay animations that kept ticking inside `NSHostingView`
windows that stay **retained after being hidden**. A saturated main thread starves the
gesture → switcher path (window enumeration + overlay show run on the main thread), so the switcher
looked slow. Only an app restart destroyed the retained hosting views and cleared it.

## Symptom

- The switcher took several seconds to appear, **intermittently**.
- Correlated with returning after a break / overnight — but **not every night**.
- Restarting the app restored normal speed for **days**.
- The Mac itself was fast, with few background apps.

## Investigation

Live forensics on the running installed build (v0.1.0), which had been launched the previous night
and been through an overnight sleep/wake:

- `ps` / `top`: the process was pinned at **~75–99% CPU**, having accumulated **~4h35m of CPU time
  over ~8h elapsed** — it had spent most of its awake life burning a core.
- macOS had filed **four `cpu_resource.diag`** energy reports under `/Library/Logs/DiagnosticReports/`
  (over several days): *"… cpu time over … seconds … exceeding limit of 50% cpu over 180 seconds."*
- A live `sample` and the diag reports showed the **same stack**, on **thread 1 (main)**, in a
  **non-frontmost** window.

### The loop (from the sample)

```
UC::DriverCore::continueProcessing()          ← SwiftUI UpdateCycle: "more work pending"
 → CA::Transaction::commit → NSDisplayCycleFlush
  → -[NSWindow layoutIfNeeded] → -[NSView _layoutSubtreeWithOldSize:]   (recurses ~40 deep)
   → _NSViewLayout → +[NSAnimationContext runAnimationGroup:]           (animated size change)
    → ViewGraphRootValueUpdater.render → ViewGraph.updateOutputs → GraphHost.runTransaction
     → AG::Subgraph::update → StaticBody.updateValue()
      → ObservationCenter.invalidate → ObservationTracking._installTracking / .cancel
       → AnyKeyPath.hash / Set<AnyKeyPath> insert+remove                (top-of-stack churn)
```

Top-of-stack leaders were `Hasher._combine/_hash`, `AnyKeyPath.hash`, and `Set<AnyKeyPath>` inside
`libswiftObservation` — the Observation-tracking machinery re-installing on every render. The run
loop never slept; it cycled `__CFRunLoopDoObservers` / `DoSource0` continuously.

Enumerating the app's on-screen windows *during* the spin showed **every window `onscreen=false`**
(hidden / ordered-out) — yet the main thread was at 99.7%. That is the tell: an ordered-out but
**retained** `NSHostingView` whose `TimelineView` keeps ticking never stops driving SwiftUI's
UpdateCycle. `orderOut` hides a window; it does **not** stop the SwiftUI animation clock inside it.

## Root cause

Purely-decorative "liveness" animations kept running forever, in windows retained after being hidden.

**The animations (all non-functional dressing):**

- `PulseHalo` / `BreathingGlowBackdrop` (`Onboarding/WizardMotion.swift`) — `TimelineView(.periodic(by: 1/20))`
  / `(1/15))` + `.scaleEffect`, running unconditionally.
- The AI-canvas "Thinking…" sparkle pulse (`Overlay/AICommandCanvasView.swift`) — a
  `TimelineView(.periodic(by: 0.6))` that, per its own comment, "keeps a calm idle pulse" even after
  thinking finished.
- The Hub gesture-preview autoplay/rehearse (`Hub/HubGesturePreview.swift` / `Hub/HubDemoDriver.swift`)
  — a self-looping `TimelineView` that also drove the caller's real overlay model.

**The retained hosts:**

- The **Hub** and **First-Touch wizard** windows are created with `isReleasedWhenClosed = false`
  (`App/AppCoordinator.swift`), so closing them only orders them out — the SwiftUI tree (with its live
  `TimelineView`s) stays retained and keeps ticking.
- The **notch "needs-you" glow** panel (`NotchAmbientGlow`, hosted by `Overlay/NotchHomeZoneController`)
  was ordered front autonomously whenever a parked AI session escalated to `.needsYou`.

Each animation tick invalidated layout on a bare hosting view (default `sizingOptions`) inside an
off-screen window; the layout never reached a fixed point (`_layoutSubtreeWithOldSize` recursing,
wrapped in `NSAnimationContext.runAnimationGroup`), so `UC::DriverCore::continueProcessing()` kept
returning `true` and the main thread spun.

## Why it correlated with "after a break," and was intermittent

Three independent triggers funneled into the same loop:

1. **Background autonomy** escalated a parked AI session to `.needsYou` while the user was away,
   lighting the animated notch glow — the trigger that fires overnight (`backgroundAutonomyEnabled` on).
2. **Wake re-layout** — after sleep/wake macOS re-lays-out all windows (including hidden retained
   ones), kicking a dormant breather window into the loop.
3. Simply having **opened + closed the Hub** / used the AI canvas earlier left a retained window
   quietly spinning.

Intermittent because it depended on whether one of these actually happened (e.g. whether a parked
session escalated that night). A restart was the only thing that **destroyed** the retained hosting
views — hence "fixed for days."

## The fix

The offending animations are non-functional liveness dressing, so removing/gating them costs no real
behavior.

1. **AI canvas thinking-pulse — removed.** The `TimelineView` sparkle in
   `AICommandCanvasView.thinkingHeaderRow` is gone (a static sparkle is kept). The functional
   elapsed-timer already freezes when reasoning ends; it stays.
2. **Notch needs-you glow — removed.** `NotchAmbientGlow` + `GlowHost` / `GlowState` / `ensureGlow` /
   `tearDownGlow` were deleted; `NotchHomeZoneController` now tracks a plain `hasNeedsYou` flag (the
   `.needsYou` state and its test seam survive; the rail still badges needs-you rows on reveal).
3. **Hub gesture preview — live-tracking → autoplay.** The live finger-tracking (rehearse seam) and
   real-model-manipulation (driven form) were removed; the preview is now a self-contained autoplay of
   the scripted swipes that **pauses when the Hub window is not visible**.

The thinking indicator and the notch needs-you cue are intended to return later in a better form.

## The guardrail (do not reintroduce this)

- A `TimelineView(.periodic)` / repeating animation must **not** run while its host window is not
  visible. Gate it on **real window visibility** (`NSWindow.occlusionState` +
  `didChangeOcclusionStateNotification`, or an explicit active flag the controller sets on show/hide)
  — **not** on SwiftUI `onAppear` / `onDisappear`, which do not fire for a hidden-but-retained window.
  Note: wrapping in `.opacity(0)` or `if isActive { … }` does **not** stop a `TimelineView` — SwiftUI
  still ticks it.
- Windows configured `isReleasedWhenClosed = false` retain their SwiftUI tree (and its animation
  clocks) after `orderOut` / `close`. Prefer releasing/destroying the hosting controller on close, or
  ensure every repeating animation inside is visibility-gated.
- **Related instance, not yet a live risk:** the onboarding wizard (`Onboarding/WizardMotion.swift`,
  `WizardActs.swift`, `FirstTouchWizardView.swift`) uses the same breathers. It is first-run-only, so
  low-frequency, but it shares the pattern — gate it the same way if it ever becomes always-present.

## Verifying it stays fixed

With the app idle and its windows hidden, `ps -o pcpu,time -p <pid>` (or Activity Monitor) should show
**~0% CPU**. Any sustained CPU while idle means a repeating animation is running in a hidden window —
re-check the guardrail. New `cpu_resource.diag` reports under
`/Library/Logs/DiagnosticReports/ThreeFingerSwitcher_*` are the canary.
