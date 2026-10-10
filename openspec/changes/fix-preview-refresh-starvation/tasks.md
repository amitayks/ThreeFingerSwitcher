# Tasks — fix preview refresh starvation

## Status: SHIPPED (2026-10-09)

Changes in `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift` and
`Sources/ThreeFingerSwitcher/App/AppCoordinator.swift`.

## Completed

- [x] Add `backgroundTask: Task<Void, Never>?` field to `ThumbnailService`
- [x] Add `unlistedAtEnumeration: Set<CGWindowID>` field to `ThumbnailService`
- [x] Extend `cancelSweeps()` to also cancel and nil `backgroundTask`
- [x] Add `prefetchBackground(_ windows: [WindowInfo])` — captures one window at a time
      in `backgroundTask`, pausing (50 ms poll) whenever `sweepTask` is non-nil
- [x] Add optional `concurrency: Int?` parameter to `refreshBatch`; default = `maxConcurrentCaptures`
- [x] In `shareableContent(covering:)`: after a fresh enumeration, set
      `unlistedAtEnumeration = Set(ids.filter { !listed.contains($0) })`; in the cached
      branch, allow reuse if all missing ids are in `unlistedAtEnumeration`
- [x] In `AppCoordinator.prefetchAllRows()`: call `thumbnails.prefetch(current, replacing: true)`
      for the visible row and `thumbnails.prefetchBackground(others)` for everything else
- [x] In `AppCoordinator.observeSleepWake()` wake handler: call
      `Task { await self.thumbnails.warmUp() }` alongside the touch-engine restart

## Verification

Build and test: `swift build && swift test` (835 tests, 0 failures).

Field verification:
- Open the switcher repeatedly on a Mac with many windows (>20) across multiple Spaces.
  The visible row should refresh within one 0.8 s timer tick regardless of how many
  off-screen windows are still capturing.
- After waking from sleep, the first switcher open should show fresh previews quickly
  (the warm-up completes in the background during the wake → open interval).
