## Why

To make the link private, two devices must establish mutual trust out-of-band. A **QR code** is the ideal carrier: one device shows a code containing a freshly-generated high-entropy secret plus its identity and long-lived key fingerprint; the other scans it. That secret authenticates an X25519 key agreement (so a man-in-the-middle who can't read the screen can't forge it), and the fingerprint lets the scanner pin the shower's key immediately. After the exchange both devices pin each other's long-lived public key, and the data link runs TLS validated against those pins. This change builds the **pure, testable heart**: the QR payload codec and the authenticated pairing **exchange** state machine (the TLS wiring + the camera UI are the platform changes that consume this).

## What Changes

- **`PairingQRPayload`** (in `DeviceLinkPairing`, shared): a versioned value carrying the device identity, a 32-byte high-entropy pairing secret, and the device's long-lived public-key (SPKI) fingerprint, with a compact string encoding (a `tfslink:` scheme + base64url) that round-trips and validates (scheme, version, field presence). The secret replaces the 8-digit code with far more entropy.
- **`PairingExchange`** (shared): a pure state machine over the QR secret. The **joiner** (scanned) opens with its ephemeral X25519 public key + identity + SPKI; the **host** (showed) replies with its own + an HMAC confirmation keyed by `HKDF(ECDH, salt: secret)`; the joiner verifies, pins the host, and confirms; the host verifies and pins the joiner. Both end **pinned** to each other iff they used the same secret; a wrong/forged secret fails confirmation (MITM defense). No I/O — driven by `PairingMessage`s a transport carries.
- **`PairingMessage`** (shared, `Codable`): the three exchange messages (`joinerHello`, `hostHello`, `joinerConfirm`).
- **Round-trip + adversarial tests** in `DeviceLinkPairingTests`: payload encode→decode; a full host↔joiner exchange ends in mutual pinning with the right identities/fingerprints; a different secret fails; a tampered confirmation fails.

## Capabilities

### New Capabilities
- `device-link-qr-pairing`: QR-based, serverless, CA-free pairing — a QR payload carrying a high-entropy secret + identity + key fingerprint, and an authenticated X25519 exchange (keyed by the secret) that ends with both devices pinning each other's long-lived key. Pure + unit-tested (incl. MITM resistance). The TLS link + the camera/QR UI consume this in the platform changes.

## Impact

- **New (in `DeviceLinkKit`):** `Sources/DeviceLinkPairing/PairingQRPayload.swift`, `PairingMessage.swift`, `PairingExchange.swift`; tests in `Tests/DeviceLinkPairingTests/`.
- **Reuses:** `PairingHandshake` conventions (X25519 + HKDF + HMAC, already MITM-proven).
- **Build/verification:** pure CryptoKit/Foundation; `swift test` in `DeviceLinkKit` covers it (payload round-trip + full exchange + adversarial).
- **Privacy/speed/UX:** privacy — the heart of it: the secret never leaves the QR/screen, trust is pinned locally, no server; UX — scan instead of type; the actual encrypted link + camera UI land in `ios-qr-pairing` / `mac-qr-pairing`.
