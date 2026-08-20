# Fix progressive CPU / latency degradation ("the longer it runs, the slower it gets")

## Why

The app degrades over hours of use: CPU creeps up, switcher previews refresh slower and slower, and the gesture trigger develops a "needs to wake up" lag — clearing only on restart. A four-way audit (repeating-work leaks, event-source lifecycle, unbounded growth, thread/QoS topology) traced it to a set of independent accumulation bugs plus a scheduling posture that let macOS starve the app whenever other apps were busy. None of these is behavior the user chose; all are lifecycle/priority defects.

## What Changes

**Progressive (accumulating) causes — removed:**

- **One multitouch device, ever.** The vendored `OpenMultitouchSupport` framework registers its OWN sleep/wake observers; its wake handler re-creates + re-registers a multitouch device WITHOUT stopping the previous one, while `AppCoordinator` independently restarts the touch engine on the same notifications — orphaning one running, callback-registered device per sleep/wake cycle. After N wakes every touch frame was processed N+1 times through one serial queue (growing CPU + touch latency). The app now strips the framework's observers at startup (ObjC-runtime, no-op if the framework changes) — the coordinator is the sole owner of sleep/wake policy.
- **Idempotent observer starts.** `MRUTracker.start()` and `KeyboardLanguageService.start()` guard against double-registration (each duplicate re-ran its work on every app activation, forever), the settings toggle sinks gain `.removeDuplicates()` (`@Published` fires on every write), and the master-enable sink's deferred body no longer ping-pongs unbounded in the no-trackpad case.
- **Wizard teardown destroys the tree.** Closing the first-run wizard window (red button) previously only `suspend()`ed the model, leaving the retained `NSHostingView`'s ungated 15–20 Hz `TimelineView` breathers ticking for the rest of the process — the documented postmortem-idle-cpu-spin loop. willClose now releases the window, model, AND hosting tree; the attract timer also drops its strong `self`.
- **Thumbnail sweeps are single-slot.** Each 0.8 s preview tick spawned an uncancelled sweep task; once a sweep overran the tick (enumeration scales with system window count) they stacked without bound. Sweeps now skip-if-busy, and the session's in-flight sweep is cancelled on overlay hide.
- **Thumbnail cache prunes + true LRU.** Closed windows' frames stayed cached until 64 newer inserts, and re-captures didn't refresh eviction order (FIFO). The cache is now pruned to the live cross-Space window set on each switcher open and evicts least-recently-STORED.
- **Stranded permission polls go quiet.** The 1 Hz permissions poll (six TCC/XPC round-trips per tick) could be pinned forever when the Hub was closed on the Setup page (`onDisappear` never fires for a retained window). The tick now no-ops unless a regular window is actually visible.
- **MRU order is pruned** to running apps on each snapshot (was append-only for the session).

**Load-sensitive causes ("can't compete with other apps") — bounded:**

- **AX messaging timeout.** Every Accessibility round-trip (several per window, inline in the gesture) carried the 6-SECOND system default; one busy peer app stalled the trigger for seconds. A process-global 0.5 s timeout is set at launch.
- **App Nap opt-out.** An LSUIElement accessory that is never frontmost is the textbook nap target — macOS demoted the touch consumer + event taps exactly when other apps were busy. `NSAppSleepDisabled` + a process-lifetime `beginActivity(.userInitiatedAllowingIdleSystemSleep)` (system idle sleep unaffected).
- **Event-tap watchdog.** The `tapDisabledByTimeout` self-heal is delivered in-band, so a system-disabled tap dropped the first post-stall gesture. A 2 s watchdog re-enables out-of-band; `stop()` also invalidates the mach port deterministically.
- **Aggregate brute-force budget.** `snapshot()`'s per-app off-Space AX sweeps (≤100 ms each) had no cross-app cap, so gesture-open cost grew with app count; a 250 ms aggregate deadline now bounds the whole snapshot (skipped apps resolve via `elementCache` and self-heal next open).
- **Dock reads throttled.** The per-mouse-move full AX walk of Dock.app (60–125 Hz near any screen edge) is cached for 80 ms; the hover model still sees every cursor sample. The `com.apple.dock` defaults handle is reused. The window-snap monitor no longer installs the per-move monitor pair it never consumed.
- **Launcher graph reused.** The launcher rebuilt its entire SwiftUI hosting view on EVERY open (main-thread graph construction at trigger time, plus a dead-graph subscription leak risk). The panel stays disposable (the ghost-on-Space-switch fix is untouched); the hosting view is now built once and re-parented.

**Second sweep (five new lenses) — what the first pass missed:**

- **A subprocess on the gesture path.** With Space-row switching on, every switcher open shelled out to `/usr/bin/defaults` on the main thread (30–100 ms, at the moment the overlay should appear). The open now reads the recognizer's cached gate.
- **Per-copy main-thread cost.** The clipboard poll hashed the whole payload byte-by-byte and fully decoded every image just to label it; a 10 MB screenshot froze gestures ~100 ms per ⌘⇧4. Bounded sample hash + header-only dimensions.
- **Standing 2 Hz taxes** (browser AX tree-walk, `cfprefsd` round-trips per raise/hover, LaunchServices lookups per cell per render in the launcher grid) are memoized or throttled.
- **Two latent crashes** (`CGWindowID(windowNumber)` on the closed Hub — every commit after the Hub had been opened once; unguarded `as!` on cross-process Accessibility data) and **one system-wide stuck state** (a sleep with three fingers down left the scroll tap swallowing all scrolling in every app) are fixed.
- **Deferred actions are tokened** (Space-settle poll, de-minimize raise, focus recovery, MC-dismiss commit, new-window single-flight), **ownership edges closed** (generation-tagged touch consumer, held observer tokens, `deinit` removals), and the **Swift 6 isolation warnings** in `KeepAwakeController` / `CursorMonitor` are resolved at the root.

Full itemized list in `tasks.md` §3.

## Capabilities

### Modified Capabilities

- `touch-input`: single-device guarantee across sleep/wake (the app owns sleep/wake policy; the framework's own observers are neutralized); consuming event taps self-heal within a bounded interval independent of event delivery.
- `menubar-app-shell`: the process opts out of App Nap (without preventing system idle sleep) and bounds every Accessibility round-trip with a process-global messaging timeout.

## Impact

- **Code:** `TouchInput/TouchEngine.swift`, `TouchInput/ScrollEventTap.swift`, `TouchInput/KeyboardSwitcherTap.swift`, `App/AppDelegate.swift`, `App/AppCoordinator.swift`, `Windows/MRUTracker.swift`, `Windows/WindowService.swift`, `Windows/ThumbnailService.swift`, `Permissions/PermissionsService.swift`, `Overlay/LauncherOverlayController.swift`, `Dock/DockPreviewController.swift`, `Dock/GlobalCursorMonitor.swift`, `Dock/AXDockReader.swift`, `KeyboardLanguage/KeyboardLanguageService.swift`, `Onboarding/FirstTouchWizardModel.swift`, `Resources/Info.plist`.
- **No new permissions, no gesture relocation, no re-login.** All Core → verifies under `swift build` / `swift test`.
- **Behavior:** feature-invisible except (a) a peer app that can't answer AX within 0.5 s drops out of that one snapshot (picked up next open) and (b) past the 250 ms aggregate brute-force budget, additional off-Space apps resolve via the element cache for that open. Both trade rare partial listings for a bounded trigger.
