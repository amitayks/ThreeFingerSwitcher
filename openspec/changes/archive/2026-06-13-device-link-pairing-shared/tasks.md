## 1. New shared package target

- [x] 1.1 `Package.swift`: add a `DeviceLinkPairing` library product + target (`Sources/DeviceLinkPairing`, v6, no deps — CryptoKit is a system framework) + a `DeviceLinkPairingTests` test target (v5).

## 2. Move the crypto

- [x] 2.1 Move `PairingCode.swift` + `PairingHandshake.swift` from `Sources/ThreeFingerSwitcher/DeviceLink/Pairing/` to `Sources/DeviceLinkPairing/` (verbatim; make the types `public`).

## 3. Move the tests

- [x] 3.1 Create `Tests/DeviceLinkPairingTests/PairingTests.swift` with the handshake + code tests (incl. MITM resistance), `import DeviceLinkPairing`.
- [x] 3.2 In Core's `PairingHandshakeTests.swift`, keep only the `PairedDeviceStore` test (remove the moved handshake/code tests).

## 4. Verify

- [x] 4.1 `swift test` green: `DeviceLinkPairingTests` (handshake/code, MITM) + Core's suite (incl. the store test) + no regressions.
- [x] 4.2 Grep: `PairingHandshake`/`PairingCode` no longer in `Sources/ThreeFingerSwitcher/`.
