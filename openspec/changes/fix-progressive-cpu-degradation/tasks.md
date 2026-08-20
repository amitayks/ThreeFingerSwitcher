# Tasks — fix progressive CPU / latency degradation

## 1. Accumulation fixes

- [x] 1.1 `TouchEngine`: strip `OpenMTManager`'s own `NSWorkspace` sleep/wake observers at init via the ObjC runtime (`NSClassFromString("OpenMTManager")` → `sharedManager` → `removeObserver`); no-op if the framework renames anything.
- [x] 1.2 `MRUTracker.start()`: idempotency guard (`observer == nil`), mirroring `WindowFocusTracker`; add `evict(keepingLive:)` and call it from `WindowService.snapshot()` next to `focus.evict`.
- [x] 1.3 `KeyboardLanguageService.start()`: idempotency guard (`activationObserver == nil`).
- [x] 1.4 `AppCoordinator`: `.removeDuplicates()` on the `$enabled` and `$keyboardLanguageEnabled` sinks (ends the no-trackpad enable→write→emission ping-pong after one lap; kills same-value re-starts).
- [x] 1.5 Wizard: willClose now fully dismantles (shared `releaseWizardReferences()` + `contentViewController = nil`); `closeWizard()` reuses it and releases the tree in both exit paths; `[weak self]` on the attract timer.
- [x] 1.6 `ThumbnailService`: single-slot `sweepTask` with generation token (`prefetch` skips while busy), `cancelSweeps()` wired into `stopPreviewRefresh()`, `Task.isCancelled` check per window in `refreshBatch`.
- [x] 1.7 `ThumbnailService.store`: true LRU (re-store moves to back); `retain(only:)` pruning wired to the switcher open's full cross-Space id set (empty set ignored — an enumeration hiccup must not wipe the last-good-frame store).
- [x] 1.8 `PermissionsService`: poll tick no-ops unless a regular (non-panel) window is visible; unconditional under `swift test` (NSApp is nil there).

## 2. Load-sensitivity fixes

- [x] 2.1 `AppDelegate`: process-global `AXUIElementSetMessagingTimeout(systemWide, 0.5)`.
- [x] 2.2 `AppDelegate` + `Resources/Info.plist`: App Nap opt-out (`beginActivity(.userInitiatedAllowingIdleSystemSleep)` held for the process lifetime; `NSAppSleepDisabled` = true). System idle sleep unaffected.
- [x] 2.3 `ScrollEventTap` / `KeyboardSwitcherTap`: 2 s `tapIsEnabled` watchdog (tolerance 1 s) re-enabling out-of-band; `CFMachPortInvalidate` on `stop()`.
- [x] 2.4 `WindowService.snapshot()`: 250 ms aggregate brute-force deadline across all per-app off-Space sweeps (past it, apps resolve via `elementCache`; next snapshot retries).
- [x] 2.5 `DockPreviewController`: 80 ms TTL cache for `reader.read()` in `handleCursor` (nil cached too); `AXDockReader`: reuse one `UserDefaults(suiteName: "com.apple.dock")` handle.
- [x] 2.6 `GlobalCursorMonitor.start()`: install the per-move monitor pair only when `onMove` is wired (the window-snap consumer uses only down/up).
- [x] 2.7 `LauncherOverlayController`: one lazily-built `NSHostingView` re-parented across disposable panels; `hide()` detaches it before `close()`.

## 3. Second sweep — five new lenses (retain cycles, main-thread I/O, SwiftUI storms, retry/poll correctness, crash/safety)

### 3a. Main-thread cost on hot paths
- [x] `openSwitcher` read `isSpaceRowSwitchingEffective`, which shells out to `/usr/bin/defaults` (fork + waitpid, 30–100 ms) — inline in EVERY switcher open for anyone with Space-row switching on. Now reads the recognizer's cached gate.
- [x] `ClipboardMonitor`: per-copy whole-payload FNV walk through `Data`'s generic iterator + a full `NSBitmapImageRep` decode (for "Image W×H") on main → bounded head/tail/length sample hash + ImageIO header-only dimensions. `ClipboardStore.stableName` walks the raw buffer.
- [x] `AXHostProvider`: the 2 Hz breadth-first AX walk of the browser (≤400 round-trips serviced by the browser's main thread) now re-validates the remembered address field (one call) and re-walks only when it fails.
- [x] `StageManager.isEnabled`: `CFPreferencesAppSynchronize` round-trip per raise / Dock hover / hold-guard tick → 2 s TTL cache.
- [x] `WindowSnapMonitor.frame(of:)`: single-id `CGWindowList` query instead of a second full on-screen enumeration per global mouse-up.
- [x] `LauncherView` / Bands editor: `NSWorkspace.icon(forFile:)` per cell per render at gesture rate → process-wide `IconCache` (stable `NSImage` identity also lets SwiftUI skip re-rasterizing). `columns` hoisted to a static.
- [x] `FavoritesStore`: full-tree JSON re-encode per keystroke → 0.3 s coalesced save (`flushStores()` at quit; tests keep synchronous saves via `saveDelay: 0`).
- [x] `ClipboardStore.bandWindow`: `.blob` entries loaded from disk did an `open`+`read` per large entry at launcher activation → per-id memo of the bounded preview.
- [x] `FirstRunStore.stage`: defaults read + String bridge per touch frame (via `wizardOwnsGestures`) → in-memory mirror with write-through.
- [x] `LaunchService.emptyTrash` off main; `run()` / `osascript` new-window use `terminationHandler` instead of parking a GCD thread in `waitUntilExit` per script.
- [x] Dock right/left-click reads route through the same 80 ms TTL as cursor moves; `AXDockReader` reuses one `UserDefaults(suiteName:)`.
- [x] SwiftUI: Hub "Window size" slider re-solve debounced (60 Hz → ~16/s); `HubWindowInspector` groups computed once per snapshot (was twice per render, per slider tick); `HubExcludedAppsEditor` enumerates running apps on appear, not per render; `SwitcherActionMap`/`LauncherActionMap` steps are `static` (stable `ForEach` identities); launcher scroll animates only on row changes; wizard `BreathingGlowBackdrop` mounted only while active.
- [x] Timer tolerances on every non-critical poll (preview refresh, clipboard, browser host, keep-awake heartbeat); tap watchdogs added to `.common` run-loop mode; per-tick `Task` allocations in the wizard attract loop and permissions poll replaced with `assumeIsolated`.

### 3b. Retry / poll / deferred-action correctness
- [x] `afterSpaceSettles`: generation token (rapid Space switches stacked N concurrent 16 Hz CGS polls, and a stale chain could focus the WRONG Space's window).
- [x] `raiseDeminimizing`'s deferred raise and `recover(attempt: 1)`'s async hop are `commitSeq`-guarded (a newer commit was being stomped / its watchdog tokens invalidated).
- [x] Mission-Control-dismiss commit deferral is a single cancellable slot.
- [x] `makeNewWindow` / `reopenWindowlessApp`: single-flight per pid (a double-lift opened two windows).
- [x] Hub / wizard `seedThumbnails` retry sweeps are cancellable and superseded per re-seed.
- [x] `WindowSnapMonitor.schedule` cancels the previous settle item.
- [x] `WindowFocusTracker` AX source in `.commonModes` (focus changes during menu/drag tracking were missed) — add, teardown AND `deinit` all agree on the mode (a mismatch there would leave a source pointing at freed memory).
- [x] `elementCache` soft-capped between snapshots; `bundleKeyByPid` pruned per snapshot; `BrowserContextMonitor`'s per-tick `bundleIdentifier` IPC memoized per pid.

### 3c. Ownership / lifecycle
- [x] `TouchEngine` consumer is generation-tagged (a stale stream side can never feed the engine alongside the new one — the app-layer twin of the framework's orphaned-device bug).
- [x] `ThumbnailService` sweep task captures `self` weakly; Hub window observers are held (not discarded); `MRUTracker` / `KeyboardLanguageService` / `WindowFocusTracker` / `InputActivityMonitor` remove their observers in `deinit`.
- [x] `KeepAwakeController.onActiveChanged` is finally wired (the menu's Active/Stop line only corrected itself on the next menu open).
- [x] `ClipboardStore.save` coalesces snapshots (latest-wins) instead of queuing a full store copy per copy.

### 3d. Crashes and stuck states
- [x] `CGWindowID(NSWindow.windowNumber)` trapped on the ≤ 0 number of the retained-but-closed Hub — on EVERY switcher commit / preview tick after the Hub had been opened once. One `hubWindowID` chokepoint + a guard in `HubSwitcherEntry.isHub`.
- [x] Unguarded `as! AXUIElement` / `as! AXValue` on cross-process AX data (traps when a misbehaving app's AX server returns another CF type) → typed `axElement` / `axValue` helpers.
- [x] `captureDimensions` traps on NaN/inf (`Swift.max(NaN, 1)` is NaN) → finite guard.
- [x] `currentFingerCount` was never reset when the touch stream stopped — sleep with three fingers down left the scroll tap swallowing EVERY scroll in every app until quit. Reset on disable / will-sleep / wake-restart, plus a 0.5 s staleness guard in the consume predicate.
- [x] `missionControlOpen` latched true when MC was closed any way but ours (stray Escape into the user's app + screen-saver-level panel on every later open) → cleared on regular-app activation, active-Space change, will-sleep, and `hideOverlay`.
- [x] `restartTouchEngineAfterWake` left both taps armed against a dead engine → `refreshRowSwitchingGate()` when availability flips.
- [x] `DockPreviewController.emptyPID` stuck (an app with no current-Space windows never got a preview again until another preview cycled) → cleared on `.idle`.
- [x] Taps re-arm on an Accessibility grant mid-session (`tapCreate` failure was discarded with nothing observing the permission).
- [x] `writeToPasteboard` no longer wipes the clipboard when it has nothing to write; `flushStores()` at quit lands coalesced favorites + clipboard writes (bounded 1 s).
- [x] `CursorMonitor` protocol is `@MainActor` (+ `onLeftUp`); `KeepAwakeController` constants are `nonisolated` — the two Swift-6 isolation warnings are gone.

## 4. Verification

- [x] 4.1 `swift build` clean (no new warnings in touched files).
- [x] 4.2 `swift test` — full suite green (783 tests, 0 failures; `ResourceBoundsTests` pins the cache LRU/prune and MRU eviction; the poll-tick NSApp guard keeps `PermissionsPollingTests` deterministic).
- [ ] 4.3 On the user's stable-signed build: after a sleep/wake cycle, confirm gestures stay single-processed (idle CPU ~0%, no growth across wakes); confirm previews stay fresh during a long switcher dwell; confirm the trigger stays instant with a CPU-loaded background app; confirm two-finger scroll still works after sleeping mid-gesture.

## Deferred (follow-ups, deliberately out of scope — see design.md Rejected)

- [ ] Move `WindowService.snapshot()` off the synchronous trigger path (warm window-list cache reconciled off-gesture; show-from-cache instantly).
- [ ] Move `ThumbnailService` capture machinery off the MainActor (actor + main-hop delivery).
- [ ] Dedicated run-loop thread (`.userInteractive`) for both CGEvent taps.
- [ ] Replace the AsyncStream + `.share()` touch delivery with a direct callback hop (removes two 1-deep frame-dropping buffers + the compiled-out priority-escalation inversion in the vendored wrapper).
- [ ] `BrowserContextMonitor`: the synchronous AppleEvents host read can block the main thread on a loaded browser; consider an async seam or timeout.
- [ ] `ClipboardStore.persist`: memoize blob names so a copy stops re-hashing every large inline payload.
