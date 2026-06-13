## Why

For QR pairing to work phone↔Mac, the Mac must also **show** a pairing QR and **accept** a scanner connecting to it. The Mac is the natural device to show the code (big screen) and the iPhone scans it. This reuses the tested `DeviceLinkPairing` crypto and the same `_tfspair._tcp` channel design as the iOS side. Trust lands in the Mac's existing `PairedDeviceStore`.

## What Changes

- **`MacLocalIdentity`** — a long-lived Curve25519 key in the macOS Keychain + its SHA-256 fingerprint (mirrors the iOS `LocalIdentity`), used in the Mac's QR payload.
- **`QRImage`** — generates a QR `NSImage` from a string (CoreImage `CIQRCodeGenerator`), with a unit-tested round-trip (generate → `CIDetector` decode → equal).
- **A Mac pairing channel** — `MacPairingChannel` (length-prefixed JSON `PairingMessage` over an `NWConnection`) + `MacPairingListener` (advertise `_tfspair._tcp` under the Mac's id, accept), mirroring iOS; plus a host `PairingExchange` runner that pins the joiner into `PairedDeviceStore` on success.
- **Hub Devices page gains "Show pairing code"** — reveals the Mac's QR and starts the pairing listener while shown; on a successful scan the new device appears in the paired list.
- **Core depends on `DeviceLinkPairing`** (already a `DeviceLinkKit` product).

## Capabilities

### New Capabilities
- `mac-qr-pairing`: the Mac side of QR pairing — a Keychain long-lived identity, QR image generation (unit-tested round-trip), a `_tfspair._tcp` listener + host `PairingExchange` runner that pins a scanner into `PairedDeviceStore`, and the Hub "Show pairing code" surface.

## Impact

- **New (in `ThreeFingerSwitcher`):** `DeviceLink/Pairing/MacLocalIdentity.swift`, `QRImage.swift`, `MacPairingChannel.swift`, `MacPairingCoordinator.swift`; `Tests/.../QRImageTests.swift`.
- **Modified:** `Package.swift` (Core deps `DeviceLinkPairing`), `Hub/HubDevicesPage.swift` (Show-code section), `App/AppCoordinator.swift` (provide the payload + start/stop the pairing listener + pin).
- **Reuses:** `DeviceLinkPairing` (`PairingQRPayload`/`PairingExchange`/`PairingMessage`) + `PairedDeviceStore`.
- **Build/verification:** `swift build` compiles the Mac pairing + view; `swift test` covers the QR image round-trip; the cross-device scan is user-verified.
- **Permissions:** the existing local-network/Bonjour (the new `_tfspair._tcp` advertise needs the same). No new entitlement.
- **Privacy/speed/UX:** privacy — the secret lives only on screen; trust pins locally; UX — show the code, scan with the phone.
