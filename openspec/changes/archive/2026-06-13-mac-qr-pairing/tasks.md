## 1. Dependency + identity + QR

- [x] 1.1 `Package.swift`: Core deps `.product(name: "DeviceLinkPairing", package: "DeviceLinkKit")`.
- [x] 1.2 `DeviceLink/Pairing/MacLocalIdentity.swift`: long-lived Curve25519 key in the Keychain + `fingerprint` + `payload(device:secret:)`.
- [x] 1.3 `DeviceLink/Pairing/QRImage.swift`: `image(from:) -> NSImage?` via CoreImage `CIQRCodeGenerator`; a `decode(_:) -> String?` helper (for the test).

## 2. Pairing channel + coordinator

- [x] 2.1 `DeviceLink/Pairing/MacPairingChannel.swift`: length-prefixed JSON `PairingMessage` over `NWConnection`; `MacPairingListener` (advertise `_tfspair._tcp` under the Mac id, accept).
- [x] 2.2 `DeviceLink/Pairing/MacPairingCoordinator.swift`: generate secret + payload (`qrString`), start the listener, run the host `PairingExchange`, pin the joiner into `PairedDeviceStore`; `start()`/`stop()`; `@Published status`/`qrString`.

## 3. Hub

- [x] 3.1 `Hub/HubDevicesPage.swift`: a "Show pairing code" section that reveals the QR (`QRImage`) and starts/stops the coordinator while shown.
- [x] 3.2 `App/AppCoordinator.swift` / `HubContext`: provide the coordinator (or its payload + lifecycle) to the page; on pair, the list refreshes from `PairedDeviceStore`.

## 4. Tests

- [x] 4.1 `Tests/.../QRImageTests.swift`: `QRImage.image(from:)` → `QRImage.decode(_:)` round-trips a payload string; decode of a non-QR image is nil.

## 5. Verify

- [x] 5.1 `swift build` clean (Core + pairing + view); `swift test` green (QR round-trip + no regressions).
- [ ] 5.2 USER (devices): show the code on the Mac, scan with the phone → the phone appears in the Mac's paired list.
