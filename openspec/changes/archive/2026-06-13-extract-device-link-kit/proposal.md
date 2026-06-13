## Why

The shared device-link packages (`DeviceLinkProtocol`, `DeviceLinkMirror`, `DeviceLinkPairing`) were targets inside the `ThreeFingerSwitcher` SwiftPM package — which is declared **macOS-only** and pulls the **MLX/Gemma** dependency. An iOS app cannot depend on a macOS-only package, and even if it could, it would drag the entire MLX graph into the iOS build. So extract the three pure packages into a standalone, cross-platform **`DeviceLinkKit`** package (macOS + iOS, zero external dependencies) that both the macOS app and the iOS companion app consume. This unblocks building the iOS app — which now compiles, launches, and renders against the iOS 26 SDK.

## What Changes

- **A new standalone `DeviceLinkKit` package** (`../DeviceLinkKit`) declaring `macOS(.v13)` + `iOS(.v17)`, with the three library products and their test targets, moved verbatim from the Mac package. No external dependency (CryptoKit is a system framework).
- **The Mac package depends on it by local path** (`.package(path: "../DeviceLinkKit")`); `ThreeFingerSwitcherCore` and the test target reference `DeviceLinkProtocol` from the package instead of an in-package target. The MLX/Gemma graph is untouched and unaffected.
- **No behavior change.** Same source, same tests — only the package home moves. The 45 device-link tests now run under `DeviceLinkKit`'s `swift test`; the Mac suite keeps its adapter/connection/store tests (which import the product).
- **The iOS companion app consumes `DeviceLinkKit`** (by local path), so the wire contract / mirror store / pairing crypto are the one shared, tested implementation across both platforms.

## Capabilities

### Modified Capabilities
<!-- None — this is a packaging refactor. The device-link capabilities' behavior is unchanged; only the
     SwiftPM package that hosts DeviceLinkProtocol/Mirror/Pairing changes. -->

## Impact

- **Moved:** `Sources/DeviceLink{Protocol,Mirror,Pairing}` + `Tests/DeviceLink{Protocol,Mirror,Pairing}Tests` → `../DeviceLinkKit/`.
- **Modified:** `Package.swift` (remove the three products + six targets; add `.package(path: "../DeviceLinkKit")`; Core + test target reference the product). New `DeviceLinkKit/Package.swift`.
- **Verification:** `DeviceLinkKit` — **45 tests green**; the iOS app builds (`xcodebuild`, iOS 26.5 simulator) and launches. The Mac suite is green except one pre-existing positional-navigation WIP gesture test (unrelated; no device-link reference).
- **Build/permissions:** no MLX impact, no new dependency, no permission change. The Mac app still builds via `xcodebuild` as before; `swift test` now spans two packages.
- **Privacy/speed/UX:** none (refactor); enables the iOS app to ship.
