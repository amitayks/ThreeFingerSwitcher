## 1. Verification Spikes (de-risk before building)

- [x] 1.1 Add Kyome OpenMultitouchSupport via SPM in a throwaway target; confirm a live touch stream prints frames on the dev machine (macOS 26 Tahoe) — fail loudly if symbols are missing/changed.
- [x] 1.2 Determine stream emission shape: log whether `touchDataStream` yields one `OMSTouchData` per touch per frame or a batched snapshot; record the finger-count derivation rule that follows.
- [x] 1.3 Observe whether starting the multitouch read triggers an Input Monitoring TCC prompt on macOS 26; record whether the permission is required.
- [x] 1.4 Confirm "Swipe between full-screen applications" can be toggled via `defaults`/`CFPreferences`; identify the exact domain/key, whether read-back reflects effective state, and whether re-login/daemon restart is needed.
- [x] 1.5 Spike ScreenCaptureKit thumbnail capture timing for ~10–20 windows; decide cache + placeholder-then-fill parameters from measured latency.

## 2. Project Scaffolding (menubar-app-shell)

- [x] 2.1 Create the Swift app project (Xcode/SwiftPM), `LSUIElement = true`, App Sandbox disabled, deployment target macOS 15.0.
- [x] 2.2 Add GPL-3 LICENSE and a NOTICE crediting AltTab for the window-raise technique.
- [x] 2.3 Add the status-bar item with a menu: Enable/Disable, Settings, Permissions/Onboarding, Quit.
- [x] 2.4 Add an AppCoordinator that owns and wires touch engine, recognizer, window service, overlay, settings; start/stop listening on enable/disable and on quit.
- [x] 2.5 Handle the no-trackpad case: detect absence, show an "unavailable — no trackpad" menu state, never crash.

## 3. Touch Input (touch-input)

- [x] 3.1 Wrap OpenMultitouchSupport in a `TouchEngine` exposing start/stop and an async stream of normalized touch frames.
- [x] 3.2 Track `id → state` to derive active finger count per the rule from task 1.2.
- [x] 3.3 Compute per-finger velocity (Δposition/Δtime) and an EMA-smoothed centroid position and velocity; expose them on the frame.
- [x] 3.4 Verify coordinates stay within 0..1 and the engine stops delivering frames after stop.

## 4. Gesture Recognition (gesture-recognition)

- [x] 4.1 Implement the gesture state machine: idle → candidate (exactly 3 fingers) → axis-locked → active → commit/cancel.
- [x] 4.2 Capture starting centroid; accumulate Δx/Δy; cancel candidate if a 4th finger lands.
- [x] 4.3 Axis-lock using the configured ratio; yield (no overlay) when vertical dominates so the OS handles Mission Control/Exposé.
- [x] 4.4 Gate the overlay on the activation threshold; below-threshold lift = no overlay, no raise.
- [x] 4.5 Implement step accumulation with carry/remainder; reversal steps back; honor wrap-vs-clamp at list ends.
- [x] 4.6 On finger lift: commit (raise highlighted window) if activated, else cancel silently; emit selection-index changes during scrub.

## 5. Window Enumeration & Raising (window-enumeration-and-raising)

- [x] 5.1 Enumerate normal windows across all Spaces via CGWindowList correlated with AX windows; exclude minimized.
- [x] 5.2 Maintain an MRU focus-history tracker (NSWorkspace activation + AX focused-window observers); fall back to z-order when history is incomplete.
- [x] 5.3 Snapshot the ordered list at gesture start; do not re-order during scrub.
- [x] 5.4 Capture thumbnails via ScreenCaptureKit with cache + placeholder-then-fill; degrade to app-icon placeholder when unavailable.
- [x] 5.5 Implement raise+focus: `AXUIElementPerformAction(kAXRaiseAction)`, set `kAXMainWindow`/`kAXFocusedWindow`, `NSRunningApplication.activate`; ensure cross-Space switch happens once at commit.

## 6. Switcher Overlay (switcher-overlay)

- [x] 6.1 Create a borderless `.nonactivatingPanel` NSPanel: `ignoresMouseEvents`, high level (e.g. `.screenSaver`), all-Spaces collection behavior, never key/main.
- [x] 6.2 Host a SwiftUI thumbnail strip: one card per snapshot window (app icon + title + thumbnail/placeholder).
- [x] 6.3 Render and animate the moving highlight bound to the selection index without rebuilding the strip.
- [x] 6.4 Auto-scroll so the highlighted card stays visible; show on the active screen; hide promptly on commit/cancel.

## 7. Native Gesture Config (native-gesture-config)

- [x] 7.1 Read current "Swipe between full-screen applications" state; if enabled, show a consent prompt (never change silently).
- [x] 7.2 On consent, persist the prior value and turn the setting off; keep Mission Control/App Exposé on three fingers.
- [x] 7.3 Offer restore-on-quit/uninstall of the persisted prior value.
- [x] 7.4 Detect effective state and warn (e.g., re-login may be required) when the native gesture still appears active.

## 8. Permissions Onboarding (permissions-onboarding)

- [x] 8.1 Detect Accessibility and Screen Recording status (and Input Monitoring per task 1.3).
- [x] 8.2 Build an onboarding UI explaining each permission with deep-links to the correct System Settings panes; reflect live status changes.
- [x] 8.3 Degrade gracefully: no Accessibility → don't raise (prompt); no Screen Recording → icon/title-only cards.

## 9. Tunable Settings (tunable-settings)

- [x] 9.1 Define a settings model with defaults: activation threshold, axis-lock ratio, step distance, wrap/clamp, direction, velocity smoothing, exact-three-fingers.
- [x] 9.2 Persist settings (UserDefaults) and apply changes live on the next gesture.
- [x] 9.3 Build a Settings UI reachable from the status menu, with reset-to-defaults.

## 10. Integration & End-to-End Verification

- [x] 10.1 Wire the full pipeline: touch → recognizer → overlay highlight → commit raise.
- [ ] 10.2 Manually verify the Windows flow: 3 fingers, slide left/right scrubs one window at a time, live; lift raises+focuses the highlighted window.
- [ ] 10.3 Verify up/down still trigger Mission Control / App Exposé while the switcher is enabled.
- [ ] 10.4 Verify horizontal no longer switches Spaces after the setting is off; verify accidental-trigger guards (threshold, axis-lock, exact-3) feel right.
- [ ] 10.5 Verify permission-denied fallbacks and the no-trackpad state.
- [ ] 10.6 Tune defaults (activation/step/axis-lock) on-device for the Windows-like feel.

## 11. Packaging & Distribution

- [x] 11.1 Configure signing + notarization for direct download (no App Store); confirm sandbox-off entitlements.
- [ ] 11.2 Produce a notarized DMG and smoke-test install on a clean account (first-run consent + permissions flow).
- [x] 11.3 Document install, permissions, the trackpad-setting change, and GPL-3 licensing in the README.
