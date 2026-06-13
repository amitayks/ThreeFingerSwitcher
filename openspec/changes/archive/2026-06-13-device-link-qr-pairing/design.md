## Context

`DeviceLinkPairing` has the X25519 + code-authenticated handshake (`PairingHandshake`), MITM-proven. QR pairing reuses that crypto but (a) carries a high-entropy secret in the QR instead of a typed code, (b) carries the shower's key fingerprint for immediate pinning, and (c) models the over-the-wire exchange as a pure state machine so it's testable. The TLS link and the camera/QR UI are platform changes that consume this.

## Goals / Non-Goals

**Goals:** a versioned QR payload string codec; a pure, tested `PairingExchange` (3-message authenticated agreement → mutual pinning); adversarial tests.

**Non-Goals:** the QR *image* generation/scan (CoreImage/Vision — platform); the TLS verify-block on the connection (platform); the long-lived identity key storage (Keychain/Secure Enclave — platform). This change deals only in the pure values + crypto.

## Decisions

**D1 — QR carries secret(32B) + identity + SPKI fingerprint.** 32 random bytes ≫ an 8-digit code, so the authenticated agreement is far stronger and the UX is a scan. The fingerprint lets the scanner pin the shower's TLS identity out-of-band. Encoded as `tfslink:` + base64url(JSON) — QR-dense, scheme-tagged, versioned. *Alternative:* reuse the 8-digit code — kept available for manual entry, but the QR's entropy is strictly better.

**D2 — Three-message exchange, secret-keyed.** joinerHello(ephemeralPK, identity, spki) → hostHello(ephemeralPK, identity, spki, confirm) → joinerConfirm(confirm). Confirmation key = `HKDF-SHA256(ECDH(eph, peerEph), salt: secret, info: "device-link-qr-v1" ‖ sorted(pubA,pubB))` (role-independent, mirrors `PairingHandshake`). HMAC confirmations prove both knew the secret; a different secret → different key → mismatch → no pin. *Alternative:* a 2-message exchange — rejected: a third message lets BOTH sides confirm the peer before pinning.

**D3 — Pure state machine returning `(reply, result)`.** `PairingExchange` has no networking; `start()` (joiner) and `consume(_:)` return the next `PairingMessage` and an optional `PairingResult` (`.pinned(identity, spki)` / `.failed`). The transport (platform) ferries the messages over the connection. This makes the whole secure handshake unit-testable by wiring two exchanges in memory.

**D4 — Pin = the peer's long-lived SPKI + identity.** The exchange outputs what the platform stores (the `PairedDeviceStore` / Keychain) and what the TLS verify block checks. The exchange itself only computes/validates; storage + TLS are platform.

## Risks / Trade-offs

- **Security-critical crypto.** → Fully unit-tested incl. the MITM (different-secret) and tamper cases; follows the proven `PairingHandshake` construction, no novel primitives.
- **The exchange's security depends on the QR secret staying out-of-band.** → It only ever lives in the QR/screen; documented; the platform must not log/transmit it.

## Migration Plan

Additive: new files + tests in the shared package. No behavior change to existing pairing. Rollback = delete the files.
