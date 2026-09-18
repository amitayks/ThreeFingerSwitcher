# Tasks: fix-audit-leaks-and-bugs

## 1. Leaks
- [x] 1.1 `Windows/CGSPrivate.swift` + `Windows/Spaces.swift`: `Unmanaged<CFArray>?` + `takeRetainedValue()` for both SkyLight Copy functions
- [x] 1.2 `Permissions/PermissionsService.swift`: poll guard requires a visible titled non-panel window
- [x] 1.3 `Windows/ThumbnailService.swift`: `existingWindowIDs()`; coordinator prunes both caches to it; `DockPreviewController.pruneThumbnails(keeping:)`
- [x] 1.4 `Clipboard/ClipboardStore.swift`: persisted payload byte size, blob-aware byte cap, post-persist externalization, `flush()` wired at quit and wipe

## 2. Preview freshness
- [x] 2.1 `ThumbnailService.prefetch(_:replacing:)`, cached `SCShareableContent`, bounded task-group captures, live-bounds capture size, in-flight wait
- [x] 2.2 `SwitcherModel` staged/coalesced publish (`publishStagedThumbnails`) + tests
- [x] 2.3 `AppCoordinator`: `prefetchAllRows()` on open, `replacing: true` on Space switch / ⌘-Tab row change, Hub demo in the `onThumbnail` fan-out

## 3. Correctness
- [x] 3.1 Danger-zone: synchronous restores before the wipe; clipboard flush before delete
- [x] 3.2 `disable()` unconditional teardown; sleep/wake gated on the opt-in
- [x] 3.3 `gestureShouldActivate()` + suppression until lift; coordinator ownership gates + tests
- [x] 3.4 `KeyboardSwitcherTap` ⌘-state resync (per event, on re-enable)
- [x] 3.5 `WindowService`: user-input guard release, `peekRaise` bumps `commitSeq`, token-gated de-minimize raise with checked AX write, focus-tracker observer retry, primary current Space, AX read reuse, legacy-path prune
- [x] 3.6 `DockPreviewController`: conditional restore, idempotent peek, sticky empty memo
- [x] 3.7 Clipboard/Launcher: own-write marker, off-main single-rep image preview with settle gate, per-tick edge suppression, grid scroll reset, icon memoization, preset completion + typed errors
- [x] 3.8 Hub/Onboarding/KeyboardLanguage: visible-only Setup re-read, drag-id hygiene, Hub card Space index, scrub-on-travel, excluded-apps dedupe, no-op store writes, AX backoff + AE timeout, tour-engine sign
- [x] 3.9 `TouchEngine` replayed-frame drop; Keep Awake `onActiveChanged` wiring

## 4. Verification
- [x] 4.1 `swift build` + `swift test` green with the new tests
- [ ] 4.2 Live check on the user's signed build: preview latency on open / Space switch, peek leave-restore, guard release on click, ⌘-Tab under a three-finger rest
