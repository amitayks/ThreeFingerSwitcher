# Verification Spike Findings (Section 1)

Recorded during `/opsx:apply`. Environment: macOS 26.4.1 (Tahoe, build 25E253), Xcode 26.5,
Swift 6.3.2, arm64, OpenMultitouchSupport 4.0.0.

## 1.1 — Live touch stream / symbols on macOS 26  ✅ RESOLVED
- `TouchSpike` builds and **links** the private `MultitouchSupport.framework` via the
  binary `OpenMultitouchSupportXCF.xcframework` (release 4.0.0).
- At runtime the framework initializes and **detects the real trackpad**:
  `Surface Dimensions: 12480 x 7680` (ratio ≈ 1.625, landscape), Driver Type 4, FamilyID 109.
- Conclusion: symbols present and device enumerated on Tahoe. The only step needing a human
  is confirming 3-finger frames print while touching — run `swift run TouchSpike` and slide.

## 1.2 — Stream emission shape  ✅ RESOLVED (from source)
- `OMSManager.shared` is a **static property** (not `shared()` as the old README showed).
- `touchDataStream` is `any AsyncShareStream<[OMSTouchData]>` — **each emission is a full
  FRAME SNAPSHOT** (array of all current touches; `[]` when all fingers lift), NOT one touch
  per emission.
- **Finger-count derivation rule**: count touches in the frame whose `state` is a *contact*
  state. Contact = `.starting | .making | .touching | .lingering`. Non-contact =
  `.notTouching | .hovering | .breaking | .leaving`. No cross-emission id tracking needed.

## 1.3 — Input Monitoring TCC prompt  ✅ RESOLVED (no prompt observed)
- Device initialization and enumeration succeeded with **no blocking Input Monitoring prompt**.
- Consistent with MultitouchSupport historically not requiring Input Monitoring.
- Onboarding still *checks* for it and can guide the user if a future OS build prompts; treat
  Input Monitoring as optional/best-effort, Accessibility + Screen Recording as required.

## 1.4 — "Swipe between full-screen applications" key  ✅ RESOLVED
- Domains (both written): `com.apple.AppleMultitouchTrackpad` and
  `com.apple.driver.AppleBluetoothMultitouch.trackpad` (global domain, not ByHost on this Mac).
- Keys: `TrackpadThreeFingerHorizSwipeGesture` (+ companion `TrackpadFourFingerHorizSwipeGesture`).
- Current machine: `TrackpadThreeFingerHorizSwipeGesture = 1` → three-finger horizontal swipe is
  CLAIMED for full-screen-app switching (the conflict we resolve).
  `TrackpadThreeFingerVertSwipeGesture = 2` → three-finger Mission Control/Exposé ON (leave alone).
- To free three-finger horizontal while keeping it available on four fingers:
  set `TrackpadThreeFingerHorizSwipeGesture = 2` and `TrackpadFourFingerHorizSwipeGesture = 1`
  (alternative: both Horiz keys `= 0` to turn full-screen swipe fully off). **Never touch Vert keys.**
- Read-back via `defaults read` reflects the stored value; runtime effect generally needs
  re-login (or a trackpad-prefs reload). Design uses **detect-and-warn**, never assume.

## 1.5 — ScreenCaptureKit thumbnail timing  ⏳ STRATEGY DECIDED (measure in-app)
- Per design D7: never capture synchronously at gesture start. `ThumbnailService` keeps an
  LRU cache keyed by window id; cards render immediately with cached image or app-icon
  placeholder, then fill/refresh asynchronously. Capture count capped to visible cards.
- Measurement to be taken from the app's own timing logs once the overlay is wired (task 5.4),
  rather than a separate throwaway harness.
