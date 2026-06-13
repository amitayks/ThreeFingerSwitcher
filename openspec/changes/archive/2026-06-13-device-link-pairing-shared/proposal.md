## Why

The pairing crypto (`PairingCode`, `PairingHandshake`) was built and tested inside `ThreeFingerSwitcherCore` (Mac-only). The iPhone app needs the **same** handshake to pair, but it cannot import Core. Duplicating security crypto is dangerous (two copies diverge; the iOS copy would be untested). So move the pure crypto into a **shared `DeviceLinkPairing` SwiftPM package** that both the Mac and the iOS app consume — one tested copy. This is a pure refactor: no behavior change, the same tests, now in the shared package.

## What Changes

- **A new `DeviceLinkPairing` library target** (CryptoKit only) holding `PairingCode` + `PairingHandshake`, moved verbatim from Core. It builds/tests on macOS and is consumable by the iOS app.
- **The handshake/code tests move** to `DeviceLinkPairingTests` (the MITM-resistance test included). The Mac's `PairedDevice`/`PairedDeviceStore` stay in Core (Mac-side persistence) — their test stays in Core's suite.
- **No behavior change**: identical types, identical tests; only their package home changes.

## Capabilities

### Modified Capabilities
- `device-link-pairing`: the pairing crypto (`PairingCode`, `PairingHandshake`) now lives in a shared `DeviceLinkPairing` package so both ends use one tested implementation. Requirements unchanged (the handshake's guarantees, incl. MITM resistance, are identical — re-verified in the shared package).

## Impact

- **Moved:** `PairingCode.swift`, `PairingHandshake.swift` → `Sources/DeviceLinkPairing/`; their tests → `Tests/DeviceLinkPairingTests/`.
- **Stays:** `PairedDevice.swift`, `PairedDeviceStore.swift` in Core (Mac persistence); the store test stays in Core's suite.
- **Modified:** `Package.swift` (new `DeviceLinkPairing` library + target + test target; CryptoKit is a system framework so no external dep).
- **Build/verification:** the moved crypto re-verifies under `swift test` in its new package; full suite stays green.
- **Privacy/speed/UX:** none (pure refactor); enables the iOS pairing change to reuse the tested crypto.
