> **Verification note:** all changed code lives in `Sources/ThreeFingerSwitcher` → the **MLX-free `ThreeFingerSwitcherCore` target**, so the authoritative compile check is `swift build --target ThreeFingerSwitcherCore` + `swift test` — **no `xcodebuild`/app build/signing is needed** (the original task wording said `xcodebuild`; corrected here). Implemented via a 5-agent workflow (3 foundation + integration + verify); build complete in ~10.6s, **661 tests pass, 0 failures, 0 repair rounds**.

## 1. Settings: persisted live-preview opt-in

- [x] 1.1 In `AppSettings.swift`, added `@Published var livePreviewEnabled: Bool` with a `didSet` persisting via `Keys.livePreviewEnabled`, plus `Defaults.livePreviewEnabled = true` and the `init` read-with-fallback — mirroring the sibling-boolean pattern (`showDiagnostics`, `requireExactlyThree`).
- [x] 1.2 Included `livePreviewEnabled = Defaults.livePreviewEnabled` in `resetToDefaults()`.
- [x] 1.3 Verify: `swift build --target ThreeFingerSwitcherCore` green; property round-trips via UserDefaults (didSet persist + init read).

## 2. Hub UI: Switcher-page toggle

- [x] 2.1 In `HubFeaturePages.swift` `SwitcherPage`, added `Toggle("Live preview of the highlighted window", isOn: $settings.livePreviewEnabled)` to the Behavior section — matched the section's bare `Toggle(_:isOn:)` idiom (siblings use bare Toggle, not `ToggleRow`, so no caption slot).
- [x] 2.2 Verify: Core build green; toggle reflects/updates the persisted value.

## 3. ThumbnailService: per-gesture live session + fast live capture

- [x] 3.1 Added `prepareLiveSession()` (one `SCShareableContent` enumeration → `[CGWindowID: SCWindow]` map + `liveDisplayUnion`), `endLiveSession()` (clears state); guards `CGPreflightScreenCaptureAccess()` and degrades silently.
- [x] 3.2 Added `liveCapture(_:logicalFrame:)` using the cached map (no per-frame enumeration), the existing `isDegradedCapture` gate, the shared `SCStreamConfiguration`, then `store` + `onThumbnail`; reuses the `inFlight` guard for self-pacing.
- [x] 3.3 Reliability fallback: a highlighted id absent from the snapshot falls back to the enumeration-based `capture(...)`; added `refreshLiveSession()` for row changes.
- [x] 3.4 Live capture never targets the synthetic Hub entry — the caller (`tickLivePreview`) excludes the Hub id the same way `prefetchCurrentRow` does; an unknown id is handled by the fallback.
- [x] 3.5 Verify: Core build green; `prefetch`/`seed`/gate behavior unchanged — `capture` now shares the extracted `streamConfiguration(for:)` helper, which is pixel-for-pixel identical to the inlined config.

## 4. AppCoordinator: live timer wired to the overlay lifecycle

- [x] 4.1 Added `livePreviewTimer: Timer?` + `livePreviewCadence` (0.1s), `startLivePreview()` (guards `livePreviewEnabled` + `overlay.isVisible`, kicks `prepareLiveSession()`, schedules the timer), and idempotent `stopLivePreview()` (invalidate+nil + `endLiveSession()`).
- [x] 4.2 `tickLivePreview()` reads `overlay.model.selectedWindow`, skips the Hub entry, computes the AX/real logical frame, and calls `thumbnails.liveCapture(...)` for the highlighted window only.
- [x] 4.3 `startLivePreview()` called in `gestureDidActivate` after `prefetchCurrentRow()`.
- [x] 4.4 Immediate kick on highlight change: `tickLivePreview()` in `gestureDidStep`; `refreshLiveSession()` + `tickLivePreview()` in `gestureDidStepRow`.
- [x] 4.5 `stopLivePreview()` paired with **every** `overlay.hide()`: `gestureDidCommit` (both paths), `gestureDidCancel`, `disable`, `handleWillSleep`, and the central `hideOverlay()` (which `AppDelegate` calls on resign-active and which the touch-engine-stop paths route through). Audited: all 6 hide sites paired.
- [x] 4.6 `observeLivePreviewToggle()` subscribes to `settings.$livePreviewEnabled` (dropFirst, emitted value): off → `stopLivePreview()`, on → `startLivePreview()` (self-guards overlay visibility).
- [x] 4.7 Verify: `swift build --target ThreeFingerSwitcherCore` green.

## 5. Guardrails: wizard demo and rendering path untouched

- [x] 5.1 Wizard demo unaffected — live capture runs only in the real gesture lifecycle in `AppCoordinator`; no live timer touches `FirstTouchWizardModel`. (`WizardActs.swift`'s working-tree change is a pre-existing, unrelated animation tweak, not part of this change.)
- [x] 5.2 Cards still render via `SwitcherModel.thumbnails[id]` in `SwitcherView` — no new render path; only the highlighted card mutates per tick.

## 6. Tests & verification

- [x] 6.1 Safety-gate pure functions (`isOffAllDisplays`/`isStripProxy`/`isDegradedCapture`) are reused unchanged and remain covered by the existing suite; no new pure helper was extracted that needs added tests (the live session requires ScreenCaptureKit, not unit-testable in isolation).
- [x] 6.2 `swift build --target ThreeFingerSwitcherCore` + `swift test` green — 661 tests, 0 failures.
- [x] 6.3 No `xcodebuild` needed: all changed code is in the MLX-free `ThreeFingerSwitcherCore` target; the app/`GemmaRuntime` target references no new symbols (the Core change is API-additive), so it is unaffected.
- [ ] 6.4 **(USER — requires keychain signing, do not run from agent shell)** Real signed build `INSTALL=1 ./scripts/build-app.sh`, then verify behavior: highlighted window updates live; live follows the selection; only one window live at a time; set-aside/strip/Hub windows never show sideways frames; toggle off restores static; no residual capture after the overlay closes (commit/cancel/sleep/resign).

## 7. Spec sync

- [x] 7.1 Synced the `switcher-overlay` (Live preview of the highlighted window) and `tunable-settings` (Live preview opt-in) deltas into the main specs, and archived the change.
