# Fix preview refresh starvation (other-Spaces sweep blocks visible row)

## Why

On Macs with many windows across Spaces, switcher preview images refresh slowly even
without a SCK hang. Symptoms on an active daily-use machine:

- **First open after wake:** previews take many seconds to appear — SCK goes cold during
  sleep and the warm-up cost hits the first session.
- **Ongoing refresh is slow:** after the initial previews land, changed windows take a
  long time to update.
- The problems compound over a long session as more windows accumulate.

Root cause: the switcher-open sweep captured the visible row AND every other Space's
windows in one `sweepTask`. The 0.8 s periodic refresh timer skips its tick while
`sweepTask` is non-nil. With many windows across many Spaces, one open sweep runs for
several seconds — every timer tick during that time is silently discarded, so the visible
row doesn't refresh again until the sweep drains. A second compounding factor: if any
window id is not present in the `SCShareableContent` listing (e.g. a newly-closed window
the app still holds a reference to), the code re-paid the full system-wide enumeration
on every tick rather than remembering that the id was absent.

## What Changes

Three targeted fixes in `ThumbnailService` and one in `AppCoordinator`:

1. **Background sweep slot (`prefetchBackground`).** The switcher-open sweep is split:
   the visible row goes into `sweepTask` (timer-refreshable as before), and the other
   Spaces' windows go into a separate `backgroundTask` that captures one window at a time
   and pauses whenever a foreground sweep is running. The timer never has to wait for
   off-screen Spaces.

2. **Unlisted-id memory (`unlistedAtEnumeration`).** After a fresh `SCShareableContent`
   enumeration, any requested ids that were NOT present are recorded in a set. Within the
   `shareableContentTTL` (3 s), a batch whose missing ids are all in this "known-absent"
   set reuses the cached listing instead of re-enumerating. Prevents one absent id from
   triggering a full enumeration every 0.8 s tick.

3. **SCK warm-up after wake.** `ThumbnailService.warmUp()` is already called at launch to
   pay SCK's one-time XPC handshake cost. It is now also called (background task) on
   `NSWorkspace.didWakeNotification` and `NSWorkspace.screensDidWakeNotification`, so the
   first post-wake switcher open doesn't stall on a cold SCK stack.

## Capabilities

### Modified Capabilities

- `window-enumeration-and-raising` → thumbnail capture: the sweep is split into a
  foreground (visible row, timer-refreshable) and background (other Spaces, one-at-a-time,
  yields to foreground) path. Timer ticks are no longer starved by off-screen work.

## Impact

- **Code:** `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift` (new
  `prefetchBackground`, `backgroundTask`, `unlistedAtEnumeration` fields, background
  concurrency param on `refreshBatch`) and `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift`
  (`prefetchAllRows` split + `warmUp` on wake).
- **No new permissions, no behavior changes.** All Core → verifies under `swift build` /
  `swift test`.
- **Trade-off:** other Spaces' rows refresh more slowly (one window at a time instead of
  four in parallel) on open. The visible row is unaffected; the background slot is
  intentionally low-throughput so it never delays what the user sees.

## Related

- [[fix-sck-hang-progressive-preview-lag]] — addresses the complementary cause: hung SCK
  calls that freeze the sweep entirely. This change addresses starvation (sweep takes too
  long); that change addresses deadlock (sweep never completes).
- [[fix-progressive-cpu-degradation]] — the original audit of progressive degradation
  bugs; established the single-slot `sweepTask` model this change extends with a
  background slot.
