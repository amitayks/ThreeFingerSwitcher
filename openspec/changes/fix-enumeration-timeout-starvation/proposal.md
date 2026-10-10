# Fix enumeration-timeout starvation (no previews when enumeration > 2 s)

## Why

v2.1.0 shows no previews on a Mac where `SCShareableContent` takes ~3.5 s. Cause: a process leaked
9,033 windows (CursorUIViewService; fixed at the source by eb2f530). The 2 s `sckTimeout` from
[[fix-sck-hang-progressive-preview-lag]] abandoned every enumeration. No capture ran. Each abandoned
request stayed queued in replayd, so the next one was slower.

## What Changes

All in `ThumbnailService`:

1. **Single-flight enumeration.** One shared `enumerationTask`. Sweeps, Dock peek, warm-up and
   diagnostics join it. A late result still fills `cachedContent`.
2. **Caller wait 3 s (`enumerationWait`), below the 4 s sweep watchdog.** The watchdog never
   supersedes a sweep that only waits. `captureImage` keeps the 2 s bound.
3. **Hung ceiling 15 s (`enumerationCeiling`).** Past it the task is abandoned and one new request
   starts. Keeps recovery from a real replayd hang; at most one orphan per 15 s.
4. **Stale-while-refresh.** A covering listing up to 30 s old is served at once while a refresh
   runs. Only a new window id (or no cache) blocks on enumeration.
5. **warmUp fills the cache** through the shared path.
6. **Diagnostics** print total windows, top owners, a leak warning (>1,000 windows per owner) and
   the enumeration time.

## Rejected

- **Caller wait 8 s.** Above the 4 s watchdog: the watchdog cancels a healthy waiting sweep, and the
  cancelled waiter does not wake (the continuation ignores cancellation). Not needed: the late
  result reaches the cache anyway.
- **No ceiling on the shared task.** One hung enumeration would be joined forever.
