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

## 3. Verification

- [x] 3.1 `swift build` clean (no new warnings in touched files).
- [x] 3.2 `swift test` — full suite green (777 tests, 0 failures; the poll-tick NSApp guard keeps `PermissionsPollingTests` deterministic).
- [ ] 3.3 On the user's stable-signed build: after a sleep/wake cycle, confirm gestures stay single-processed (idle CPU ~0%, no growth across wakes); confirm previews stay fresh during a long switcher dwell; confirm the trigger stays instant with a CPU-loaded background app.

## Deferred (follow-ups, deliberately out of scope — see design.md Rejected)

- [ ] Move `WindowService.snapshot()` off the synchronous trigger path (warm window-list cache reconciled off-gesture; show-from-cache instantly).
- [ ] Move `ThumbnailService` capture machinery off the MainActor (actor + main-hop delivery).
- [ ] Dedicated run-loop thread (`.userInteractive`) for both CGEvent taps.
- [ ] Replace the AsyncStream + `.share()` touch delivery with a direct callback hop (removes two 1-deep frame-dropping buffers + the compiled-out priority-escalation inversion in the vendored wrapper).
- [ ] `BrowserContextMonitor`: the synchronous AppleEvents host read can block the main thread on a loaded browser; consider an async seam or timeout.
- [ ] `ClipboardStore.persist`: memoize blob names so a copy stops re-hashing every large inline payload.
