## 1. Standalone package

- [x] 1.1 Create `../DeviceLinkKit/Package.swift` (macOS .v13 + iOS .v17; 3 library products + 3 targets + 3 test targets; no external deps).
- [x] 1.2 Move `Sources/DeviceLink{Protocol,Mirror,Pairing}` and `Tests/DeviceLink{Protocol,Mirror,Pairing}Tests` into `DeviceLinkKit/`.

## 2. Repoint the Mac package

- [x] 2.1 `Package.swift`: remove the three library products + six device-link targets; add `.package(path: "../DeviceLinkKit")`.
- [x] 2.2 `ThreeFingerSwitcherCore` deps `.product(name: "DeviceLinkProtocol", package: "DeviceLinkKit")`; the test target gains the same product dep (the adapter/connection tests import it).

## 3. Verify

- [x] 3.1 `cd DeviceLinkKit && swift test` → green (45 tests).
- [x] 3.2 `swift test` (Mac repo) → green except the pre-existing positional-navigation WIP gesture test (unrelated; no device-link reference).
- [x] 3.3 iOS app builds (`xcodebuild`, iphonesimulator 26.5) and launches/renders — consuming `DeviceLinkKit`.
