# Design — fix SCK hang → progressive preview lag

## Context

`ThumbnailService` captures window screenshots via two ScreenCaptureKit calls: `SCShareableContent.excludingDesktopWindows` (enumerates all windows) and `SCScreenshotManager.captureImage` (takes one screenshot). Both are `async throws` — they suspend until `replayd` answers. `replayd` occasionally enters a state (confirmed across sessions on affected Macs) where it stops answering. Because there was no timeout, a single hung call froze the owning task indefinitely, and the effects compounded:

1. The window's id sat in `inFlight` → `captureSlot`'s 20-tick wait guard hit its 300 ms bound and returned `nil`, but the ORIGINAL call was still alive and the id was never removed.
2. `sweepTask` was still non-nil → every subsequent `prefetch` (timer OR explicit) saw `sweepTask != nil` and returned early (skip-if-busy).
3. Periodic refresh was dead for the rest of the session.

Each additional `replayd` hang compounded: more frozen windows, no recovery path.

## Decisions

### D1 — Unstructured child task, not a TaskGroup child

A `TaskGroup` child that hangs blocks `group.next()` (the group scope waits for every child to finish before it can complete). An unstructured `Task` that is abandoned truly abandons the work: the continuation resumes on timeout, the parent proceeds, and the hung task can drain on its own. The cost: the abandoned Task holds a `SCWindow` handle and a `SCStreamConfiguration` until `replayd` eventually replies or the process exits — acceptable since this is the pathological case, not the hot path.

### D2 — 2 s per-call timeout

Normal `captureImage` round-trips complete in 50–300 ms; `SCShareableContent` enumeration in 100–300 ms on a busy Mac. 2 s is a 6–10× headroom — generous enough that a legitimately-slow-but-healthy SCK never times out, tight enough that a hung call releases its `inFlight` slot well before the next sweep's 0.8 s timer tick arrives for the second time. Tunable via `sckTimeout` constant if field data suggests a different threshold.

### D3 — Sweep watchdog at 4 s (separate from per-call timeout)

The per-call timeout covers the pathological SCK call. The watchdog covers a rarer scenario: the Swift runtime fails to deliver the timeout (e.g. a blocking C call inside SCK that Task cancellation cannot interrupt). 4 s ≈ 5× the sweep's normal duration with a full row of windows; a sweep still running after 4 s is definitionally wedged. The watchdog fires on the NEXT timer tick (not proactively), so the recovery cadence is at most 0.8 s + 4 s = 4.8 s of total frozen time in the worst case.

### D4 — `TimeoutOnce` as a file-private class, not a local nested type

Swift does not allow a concrete class nested inside a generic function (`withTimeout` is generic over `T`). Hoisted to file scope as `private final class TimeoutOnce` — the lock-guarded `claim()` ensures the `CheckedContinuation` is resumed exactly once regardless of which of (result, error, timer) arrives first.

### D5 — `captureOne` path inherits the timeout via `shareableContent` and `captureWindow`

The Dock preview's `captureOne` (single-window path for peek captures) calls the same `shareableContent` and `captureWindow` helpers. Both now have the 2 s bound, so the Dock path benefits from the fix without any separate change.

## Rejected

- **Wrapping inside a `TaskGroup` child with a `withTaskCancellationHandler`** — cancellation is cooperative; `replayd` stall is not a Swift-cancellation-aware path. The group still waits for the child to acknowledge cancellation, which it never does.
- **Raising `maxConcurrentCaptures` to drain faster** — more concurrent hung calls would saturate `replayd` faster, not less. The right bound for concurrency is latency-driven (4 parallel for a normal row), not recovery-driven.
- **Resetting `replayd` via `SCStream.stopCapture` or process kill** — we don't own the process, and a force-kill of `replayd` would drop all other apps' screen recordings. Not viable.
- **Increasing `shareableContentTTL` to skip the enumeration call more often** — reduces exposure to the enumeration hang for cached cases, but does not fix the `captureImage` hang (the more common of the two observed failure modes) and silently widens the stale-frame window for window count/position changes. Not a fix.
