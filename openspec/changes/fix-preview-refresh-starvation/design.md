# Design — fix preview refresh starvation

## Context

`prefetchAllRows()` (called on every switcher open) assembled all windows across all
Spaces into one array and passed them to `prefetch(..., replacing: true)`, which put
everything into `sweepTask`. The 0.8 s timer calls `prefetchCurrentRow()` which calls
`prefetch(...)` with `replacing: false` — skip-if-busy. So: one open with 60 windows
across 5 Spaces → ~60 captures at 4-concurrent, maybe 6–10 s total → 8–12 timer ticks
silently dropped → the row the user is staring at doesn't refresh until the other Spaces
finish. The degradation compounds as windows accumulate over the day.

## Decisions

### D1 — Two task slots, not one

The core fix: `sweepTask` (foreground, timer-refreshable) vs `backgroundTask`
(other-Spaces, low-priority). `cancelSweeps()` cancels both. The timer only gates on
`sweepTask`, so background work running concurrently never causes a tick to be skipped.

### D2 — Background concurrency = 1

`prefetchBackground` calls `refreshBatch(windows:, concurrency: 1)` per window, one at a
time in order. This is deliberately conservative: the visible row's foreground sweep runs
4-concurrent and is what the user sees; background work is best-effort. Adding a
concurrency param to `refreshBatch` (`concurrency: Int? = nil`, defaults to
`maxConcurrentCaptures`) avoids duplicating the batch machinery.

### D3 — Background yields to foreground sweep

Inside `prefetchBackground`'s task loop, each iteration checks `sweepTask != nil` and
sleeps 50 ms if so. This ensures that an explicit refresh (switcher open or Space switch)
preempts the background work immediately.

### D4 — `unlistedAtEnumeration` is cleared on each fresh enumeration

After a `SCShareableContent.excludingDesktopWindows` call, `unlistedAtEnumeration` is set
to `ids.filter { !listed.contains($0) }` — the ids the caller wanted that SCK didn't
list. Within the TTL (3 s), any batch whose "missing" ids are all in this set reuses the
cached listing. On the next re-enumeration the set is overwritten (the window may have
closed, and its id should now be absent from future batches too).

Why not widen the TTL instead? A wider TTL misses new windows (a window opened 4 s ago
wouldn't appear) and doesn't fix the enumeration call at all — only batches whose ids are
ALL present skip it. The `unlistedAtEnumeration` approach fixes the specific anti-pattern
(one dead id forces full re-enumeration every tick) without widening the stale window.

### D5 — warmUp on wake, not on every session start

`warmUp()` is already called at `AppCoordinator.init` (task). The same call on wake
re-pays the XPC handshake with `replayd` which seems to go cold after sleep. Calling it
on both `didWakeNotification` and `screensDidWakeNotification` matches the existing
touch-engine restart pattern. The warmup task is fire-and-forget; if it fails, the first
real capture pays the cost as before.

## Rejected

- **Cancelling the other-Spaces sweep when the timer fires.** Too aggressive — would mean
  other Spaces never finish refreshing on a busy Mac. The yield-to-foreground approach is
  gentler: background pauses briefly, then resumes.
- **Caching `SCShareableContent` longer (e.g. 10 s) to reduce enumeration cost.** Misses
  new windows for longer and doesn't fix the missing-id re-enumeration anti-pattern
  specifically.
- **One background task per window (unstructured Tasks fan-out).** Would contend with the
  foreground sweep's 4-concurrent captures; sequential single-slot is cheaper.
