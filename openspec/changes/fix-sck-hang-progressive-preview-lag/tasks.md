# Tasks — fix SCK hang → progressive preview lag

## Status: SHIPPED (2026-10-09)

All changes are in `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift`.

## Completed

- [x] Add `sckTimeout: TimeInterval = 2.0` constant and `sweepStaleAfter: TimeInterval = 4.0` + `sweepStartedAt: TimeInterval` fields to `ThumbnailService`
- [x] Add file-private `TimeoutOnce` class (lock-guarded one-shot claim flag for the continuation)
- [x] Implement `nonisolated static func withTimeout<T>(_ seconds:, _ operation:) async throws -> T?`
- [x] Wrap `SCShareableContent.excludingDesktopWindows` call in `shareableContent` with `withTimeout(sckTimeout)`
- [x] Wrap `SCScreenshotManager.captureImage` call in `captureWindow` with `withTimeout(sckTimeout)`; on timeout log `[TFS-thumb] capture id=… TIMED OUT` if `frameLoggingEnabled`
- [x] Record `sweepStartedAt = CACurrentMediaTime()` in `prefetch` when starting a new sweep
- [x] In `prefetch`, compute `wedged = CACurrentMediaTime() - sweepStartedAt > sweepStaleAfter`; allow skip-if-busy to be bypassed for wedged sweeps (same as `replacing: true`)

## Verification

Build and test: `swift build && swift test` (835 tests, 0 failures).

Field verification on the affected Mac:
- Launch with `TFS_THUMB_LOG=1` and watch Console for `[TFS-thumb] capture id=… TIMED OUT` — if these appear and previews stay fresh, the hang was the cause.
- Sustained use session: previews should stay current indefinitely, no 30 s lag.

## Follow-up

[[fix-preview-refresh-starvation]] — addresses the complementary starvation cause diagnosed on the same Mac: other-Spaces sweep occupying the single sweep slot and blocking the 0.8 s timer refresh of the visible row.
