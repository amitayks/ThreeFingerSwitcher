## 1. ThumbnailService — collapse to a batch refresh of the visible row

- [x] 1.1 Drop the `hasCachedFrame` short-circuit so a cleanly-presented window is re-captured even when cached: `shouldPrefetchCapture` now takes only `(displayedFrame, realFrame, displayUnion)` and returns `!isOffAllDisplays && !isStripProxy`. `isOffAllDisplays` / `isStripProxy` / `isDegradedCapture` / `cleanScaleThreshold` unchanged.
- [x] 1.2 Restructured the capture pass so a sweep enumerates `SCShareableContent` ONCE (`refreshBatch`) and captures each cleanly-presented window from that single snapshot via the shared `captureWindow`, sequentially, self-paced by `inFlight`. `prefetch(_ windows:)` kept as the public entry (kicks `refreshBatch`).
- [x] 1.3 Deleted the per-gesture live-session machinery: `liveCapture`, `prepareLiveSession`, `refreshLiveSession`, `endLiveSession`, and the `liveWindows` / `liveDisplayUnion` snapshot.
- [x] 1.4 Deleted the laggy per-tick settle machinery: `liveSettleTicks`, `liveSettleStep(...)`, `liveBoundsSeen` (and initially `liveBounds`). *(§5 re-adds `liveBounds` to power the new stateless motion gate — a different mechanism.)*
- [x] 1.5 Retained surface confirmed compiling: `seed`, `cached`, `inject`, `warmUp`, `clear`, `store`, `captureDimensions`, `streamConfiguration`, `diagnosticFrames`, `displayUnion` (no behavior change; one stale doc comment fixed).
- [x] 1.6 Preserved the Dock preview's one-shot capture: added `captureOne(_ id:logicalFrame:)` (enumerate-one → `captureWindow`, no motion gate — the Dock waits its own settle delay) and updated `DockPreviewController` to call it. This also fixes a latent bug where the motion gate's "first observation defers" skipped the Dock's single post-settle capture.

## 2. AppCoordinator — periodic preview-refresh timer

- [x] 2.1 Renamed: `livePreviewTimer` → `previewRefreshTimer`; `livePreviewCadence: 0.1` → `previewRefreshInterval: 0.8` (made `internal` so a test can guard the cadence).
- [x] 2.2 `startLivePreview()` → `startPreviewRefresh()`: `previewRefreshInterval` repeating timer whose tick calls `prefetchCurrentRow()` (whole visible row). Removed the `prepareLiveSession()` call. Idempotent.
- [x] 2.3 `stopLivePreview()` → `stopPreviewRefresh()`: invalidate the timer only (no `endLiveSession`). All teardown call sites (commit / cancel / touch-engine stop / resign-active / sleep / disable) renamed via the unique method name.
- [x] 2.4 Removed `tickLivePreview()` (single highlighted-window capture); the timer's visible-row refresh replaces it.
- [x] 2.5 Removed the eager per-scrub kicks in `gestureDidStep` and `gestureDidStepRow` (`.moved` → `break`). In `switchSpace`, kept the immediate `prefetchCurrentRow()` (now a real re-capture of the new row) + `beginSlideFreeze()`; dropped `refreshLiveSession()` and `tickLivePreview()`.
- [x] 2.6 `gestureDidActivate()` confirmed: `seedAllRows()` → `prefetchCurrentRow()` (immediate visible-row capture) → `startPreviewRefresh()`.
- [x] 2.7 Audited the wizard `prefetch` sites (`AppCoordinator:2145/2152`): they capture only never-cached `missing` windows, so dropping the cached-skip is compatible and matches their "live-captures every cleanly-presented window" intent. No change needed.

## 3. Tests

- [x] 3.1 Removed the `liveSettleStep` motion-gate tests in `OffSpaceFidelityTests.swift` (function deleted).
- [x] 3.2 Updated the `shouldPrefetchCapture` tests for the dropped `hasCachedFrame` param: removed the "skip when cached" case; kept cleanly-presented ⇒ capture, off-all-displays ⇒ skip, strip-proxy ⇒ skip (renamed to `testRefresh*`).
- [x] 3.3 Kept the `isOffAllDisplays` / `isDegradedCapture` / `isStripProxy` tests unchanged.
- [x] 3.4 Added `testPreviewRefreshIntervalIsSlowNotLive` (asserts `AppCoordinator.previewRefreshInterval >= 0.5` — guards against a regression to a 0.1s live loop).

## 4. Verify & sync

- [x] 4.1 `swift build --target ThreeFingerSwitcherCore` clean + `swift test` green (929 tests, 0 failures; no references to deleted symbols remain).
- [x] 4.2 `xcodebuild` compile-verify of the app target: `ThumbnailService.swift` / `AppCoordinator.swift` / `DockPreviewController.swift` compiled with 0 errors. (Full MLX/Metal link runs past the agent timeout — that's the unaffected MLX shader cost, not this change.)
- [x] 4.3 Synced the delta into `openspec/specs/switcher-overlay/spec.md` (via `openspec archive`, at archive time).
- [x] 4.4 In-app behavior accepted by the user, who signed off by archiving the change. (User-run `INSTALL=1 ./scripts/build-app.sh` is the path for any further feel-tuning of `previewRefreshInterval`.)

## 5. Robust sideways detection (follow-up: catch bad frames before they render)

- [x] 5.1 Re-added `ThumbnailService.liveBounds(of:)` — a cheap single-id `CGWindowList` LIVE read that tracks an in-flight Stage-Manager / Dock animation frame by frame.
- [x] 5.2 Added the pure `frameMovedDuringCapture(before:after:) -> Bool` (exact `CGRect` inequality) — the stateless motion signal.
- [x] 5.3 `captureWindow` now (a) gates `isDegradedCapture` on the FRESH `liveBounds` (static-degraded: set-aside strip / off-display), and (b) reads `liveBounds` before AND after the screenshot, discarding the frame (nothing stored) when it moved across the capture — so a tilted "sideways" frame never replaces the last good one. A still window passes both gates immediately (no added latency).
- [x] 5.4 The Dock preview's `captureOne` inherits the motion gate via the shared `captureWindow` (also stops storing a frame grabbed while a peeked window is still animating forward).
- [x] 5.5 Tests: added `testStillFrameIsNotInMotion` / `testMovedFrameIsInMotion` / `testEvenOnePixelShiftIsInMotion`; `swift build` + `swift test` green (932 tests, 0 failures).
- [x] 5.6 Updated artifacts: spec requirement now specifies the two-gate "reject before render" model with scenarios; design D5/D6 + Risks revised.
