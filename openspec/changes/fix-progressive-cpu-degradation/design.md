# Design — fix progressive CPU / latency degradation

## Context

Live forensics on the installed build plus a four-way code audit identified two failure families:

1. **Accumulation with use** — work that is created per event/session/wake and never fully torn down, so the per-event cost grows monotonically over a session (the user's "the more I use it the slower it gets").
2. **Priority starvation under load** — the latency-critical gesture path runs entirely on the main thread at default priority, makes unbounded synchronous cross-process Accessibility calls, and the process carried no App Nap protection — so *other* apps' load became *our* latency (the user's "it can't fight for the Mac's resources").

## Decisions

### D1 — Neutralize the framework's sleep/wake observers via the ObjC runtime (not a fork)

`OpenMTManager` (prebuilt binary XCFramework) registers `willSleep`/`didWakeUp` observers in its `init`; `didWakeUp` unconditionally re-creates + re-registers + re-starts a multitouch device, and `makeDevice` overwrites its device pointer without stopping/releasing the old one. `AppCoordinator` ALSO restarts the touch engine on the same notifications (it must — the device source dies across sleep), so each full sleep/wake cycle orphaned one running device: N wakes → every touch frame processed N+1 times through the framework's single `dispatch_sync` serial queue.

Chosen fix: at `TouchEngine` init (after the singleton exists), `NSWorkspace.shared.notificationCenter.removeObserver(<OpenMTManager.sharedManager via NSClassFromString/perform>)`. Rationale over forking/vendoring a patched framework: zero build-pipeline change, degrades to a no-op if the framework renames anything (worst case = old behavior), and the coordinator already owns the sleep/wake policy (its pre-sleep `touchEngine.stop()` also dodges the framework's use-after-free `willSleep` probe, which this removal eliminates outright).

### D2 — Bound AX with a process-global messaging timeout, not per-call plumbing

`AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)` at launch sets the default for every AX message the process sends. 0.5 s: generous for a merely-busy app (normal replies are sub-millisecond), 12× better worst case than the 6 s default, and a hung app costs at most ~0.5 s per call instead of stalling the gesture indefinitely. A peer that times out drops from that snapshot only; the next open retries.

### D3 — App Nap opt-out that never blocks system sleep

`NSAppSleepDisabled` (plist) + `beginActivity(options: [.userInitiatedAllowingIdleSystemSleep])` held for the process lifetime. Explicitly NOT `.userInitiated` (it includes `idleSystemSleepDisabled` — a menu-bar utility must never keep the Mac awake) and NOT `.latencyCritical` (power cost; unnecessary once napping is off).

### D4 — Single-slot, cancellable thumbnail sweeps (skip, never queue)

The per-window `inFlight` guard gave per-WINDOW back-pressure but not per-SWEEP: overlapping sweeps each paid a full `SCShareableContent` enumeration. One `sweepTask` slot + a generation token; `prefetch` skips while a sweep runs (sweeps are idempotent refreshes), `stopPreviewRefresh()` cancels the in-flight sweep, `refreshBatch` checks `Task.isCancelled` between windows. `captureNow` (capture-before-minimize) stays await-based and unaffected.

### D5 — Wizard: destroy on close; the Hub's flag-gating stays the Hub's

The Hub fixed the postmortem loop with a visibility flag because its window is REUSED. The wizard is rebuilt from persisted state on every entry (`showFirstTouchWizard` checks `wizardWindow == nil`), so the cheaper, stronger fix is teardown: willClose releases window + model + hosting tree (`contentViewController = nil` — the only reliable way to stop a `TimelineView` in a retained host). The shared `releaseWizardReferences()` removes the close observer first so `closeWizard()`'s own `close()` can't re-enter.

### D6 — Launcher: disposable panel, persistent SwiftUI graph

The per-hide panel destruction is a verified ghost-on-Space-switch fix and stays. The expensive/leak-prone part was never the `NSPanel` — it was the `NSHostingView` graph (main-thread construction per open; each dead graph's `model` subscription lives until its panel truly deallocates). One hosting view is created lazily and re-parented into each fresh panel; `hide()` detaches it (`contentView = nil`) before `close()` so it deterministically survives the window.

### D7 — Permissions poll: gate the tick, don't re-plumb the refcount

The refcount design is fine; the failure mode is a stranded unbalanced `startPolling()` when a retained window closes under a SwiftUI `.onDisappear` that never fires. Rather than teaching every window owner to balance counts, the tick itself no-ops unless a regular (non-`NSPanel`) window is visible — a stranded poll costs an empty 1 Hz timer instead of six cross-process probes per second. `NSApp` is nil under `swift test`; the tick polls unconditionally there to stay testable.

### D8 — Snapshot brute-force: aggregate deadline over per-app budgets

Per-app 100 ms budgets bound each sweep but not the sum. A single `DispatchTime` deadline (250 ms) is captured at snapshot start; past it, remaining apps get an empty brute-force map and resolve through `elementCache` (windows seen reachable before stay raisable). Coverage self-heals across opens. 250 ms ≈ 2–3 slow apps' worth — the previous common case — while capping the pathological many-app case.

### D9 — Dock cursor path: cache the AX walk for 80 ms, cache nothing else

The "reader caches nothing" contract exists so magnification/auto-hide reveal read fresh — but per-EVENT freshness (60–125 Hz) was never needed for tile frames; the popup's own 0.12 s timer defines the feature's real cadence. An 80 ms TTL snapshot cache (nil results included — an auto-hidden Dock reads empty) keeps every behavior at its designed cadence while cutting the AX walk rate ~10×. The hover model still receives every cursor sample (grace/anchor timing unchanged).

## Rejected

- **Forking OpenMultitouchSupport** — heavier to maintain than runtime observer removal; revisit only if the framework's internals change enough to break the removal (which fails safe).
- **`.latencyCritical` activity / dedicated event-tap thread / ThumbnailService off MainActor / warm window-list cache for `snapshot()`** — real candidates, deliberately deferred: each is an architecture change with its own landmines, and the accumulation fixes + timeout + nap opt-out address the reported symptoms directly. Documented as follow-ups in tasks.md §Deferred.
- **Reusing the launcher PANEL** (à la `OverlayController.prewarm`) — conflicts with the verified ghost-on-Space-switch fix; the graph reuse captures the win without the risk.
