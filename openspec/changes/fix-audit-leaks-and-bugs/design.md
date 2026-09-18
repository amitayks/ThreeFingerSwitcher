# Design notes

## Preview freshness: replace, don't queue

`ThumbnailService.prefetch(_:replacing:)` keeps the single-slot sweep model from `fix-progressive-cpu-degradation` (a sweep is an idempotent refresh, never a queue) and adds ONE exception: an explicit refresh — switcher open, Space switch, ⌘-Tab row change — cancels the in-flight sweep (it is refreshing the row the user just left) and starts its own. The periodic 0.8 s tick stays skip-if-busy. Inside a sweep, captures run through a `withTaskGroup` bounded to four concurrent ScreenCaptureKit screenshots, in caller order (visible row first), and the `SCShareableContent` listing is cached for three seconds and reused while it lists every target id. Capture size comes from the window's live bounds so a cached listing never sizes a resized window wrong. `captureSlot` waits (bounded, 15 ms × 20) for a still-running capture of the same id from a cancelled sweep instead of skipping the window.

`SwitcherModel.setThumbnail` stages live frames and publishes them once per ~16 ms (`publishStagedThumbnails`); seeds stay immediate; a freeze started while frames are staged takes them over as pending; `flushThumbnails` and `setRows` fold or drop the staging buffer. This bounds reel re-renders to one per frame regardless of how many captures land together.

The prune set for both thumbnail caches is `ThumbnailService.existingWindowIDs()` (`kCGWindowListOptionAll`), not the switcher snapshot.

## Ownership: refuse at the source

`GestureRecognizerDelegate.gestureShouldActivate()` (default true) is asked before `activated = true`. A refusal drops the whole touch until every finger lifts (`suppressedUntilLift`), so the recognizer never emits step/commit/cancel for it. The coordinator also gates `gestureDidStep*`, `gestureDidCommit`, `gestureDidCancel` on `switcherOwner != .keyboard` as a belt for a gesture already in flight when the keyboard session opened.

## Focus guards vs. the user

`WindowService` installs one passive global monitor (left/right mouse down, keyDown with ⌘) while a watchdog or hold-guard is pending; the first such event bumps `commitSeq` (invalidating every pending tick), logs a trace, and removes the monitor. Plain typing does not cancel (the target has focus then anyway). `peekRaise` bumps `commitSeq` too. The de-minimize deferred raise snapshots `commitSeq` and bails if it advanced.

## Danger zone

`restoreAllNativeGestures` restores each config synchronously before flipping the flags; the deferred flag observers then find no backup and no-op. `clipboardStore.flush()` runs after `clipboardMonitor.stop()` and before `appDataReset.clear`.

## Rejected

- Consuming the trackpad touch only in `gestureDidActivate` (the old behavior): the recognizer still marked itself activated and the lift still committed/cancelled the other driver's session.
- Cancelling the focus guards on `didActivateApplication`: under Stage Manager the WindowManager steal itself can post that notification, defeating the guard it exists for.
- Streaming SCK captures for the row: reverted earlier for the Dock; the cached enumeration + bounded parallel one-shots give the latency win without a stream.
