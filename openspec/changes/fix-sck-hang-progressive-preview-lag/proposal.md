# Fix SCK hang → progressive preview lag

## Why

On some Macs, switcher preview images stop updating over time — after sustained use the delay before a changed window's thumbnail appears grows to ~30 s. The degradation is progressive (starts fast, grows with runtime) and clears on restart.

Root cause: `SCShareableContent.excludingDesktopWindows` and `SCScreenshotManager.captureImage` (the two ScreenCaptureKit calls in `ThumbnailService`) occasionally never return. The macOS `replayd` XPC service can enter a state where it stops answering, with no timeout on the caller side. When this happens:

- The window's id stays in `inFlight` forever → that window is never re-captured.
- The `sweepTask` never completes → every subsequent 0.8 s timer tick is silently skipped (`skip-if-busy` guard).
- Each new hang adds another permanently-frozen window and, once the sweep is stuck, periodic refresh stops entirely.
- The user notices ~30 s delays because only explicit open/Space-switch events can attempt a refresh, and even those are blocked by the stuck sweep.

## What Changes

Two targeted bounds in `ThumbnailService`:

1. **Per-call timeout (2 s).** A `withTimeout` helper wraps both SCK calls. On timeout: the window's `inFlight` entry is released (via the caller's `defer`) so the next sweep can retry it; the cached last-good frame is kept. The helper uses an unstructured child Task + `CheckedContinuation` so the hung SCK work is abandoned — a `TaskGroup` child would still block the group's scope.

2. **Sweep stale watchdog (4 s).** `prefetch` records `sweepStartedAt` alongside `sweepTask`. A sweep older than 4 s is treated as wedged: the next timer tick (which would normally be skipped) supersedes it via `cancelSweeps()`. This gives periodic refresh a recovery path even if the per-call timeout fails to fire (e.g. if the hang occurs inside a system-owned continuation the Swift runtime can't cancel).

## Capabilities

### Modified Capabilities

- `window-enumeration-and-raising` → thumbnail capture: SCK calls are now bounded. A wedged call releases its resources within 2 s instead of holding them for the process lifetime.

## Impact

- **Code:** `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift` only.
- **No new permissions, no behavior changes for non-hung paths.** All Core → verifies under `swift build` / `swift test`.
- **Trade-off:** a SCK call that takes just over 2 s (legitimately slow, not truly hung) will be abandoned, leaving the last-good frame in place until the next sweep retries. In practice SCK screenshots complete in <300 ms; 2 s is a 6× headroom.

## Related

- [[fix-progressive-cpu-degradation]] — addressed the earlier generation of progressive-degradation bugs (device accumulation, sweep stacking, wizard teardown)
- [[fix-audit-leaks-and-bugs]] — established the single-slot sweep model (`sweepTask`, `inFlight`, `captureSlot`) that this change extends
