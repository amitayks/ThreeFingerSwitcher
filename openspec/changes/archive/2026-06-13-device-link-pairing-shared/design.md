## Context

`PairingCode`/`PairingHandshake` are pure CryptoKit, tested in Core. The iOS app can't import Core, so the crypto must move to a shared package. Nothing in Core references these types outside the Pairing/ dir and tests (verified), so the move is safe.

## Goals / Non-Goals

**Goals:** one shared, tested copy of the pairing crypto consumable by both ends; no behavior change.

**Non-Goals:** moving `PairedDevice`/`PairedDeviceStore` (Mac persistence; the iOS app stores its pin in Keychain separately); the TLS wiring (still the follow-up).

## Decisions

**D1 — A dedicated `DeviceLinkPairing` package, not folding crypto into `DeviceLinkProtocol`.** `DeviceLinkProtocol` is deliberately Foundation-only (zero frameworks); the pairing crypto needs CryptoKit. A separate package keeps the wire contract pure and isolates the CryptoKit dependency. *Alternative:* add CryptoKit to `DeviceLinkProtocol` — rejected (muddies the pure wire package).

**D2 — Tests split by home.** Handshake + code tests move to `DeviceLinkPairingTests`; the `PairedDeviceStore` test stays in Core's suite (it tests Core persistence). The MITM-resistance test travels with the handshake.

## Risks / Trade-offs

- **A refactor touching archived code's files.** → Pure move (no edits to the type bodies), re-verified by the same tests; full suite must stay green.

## Migration Plan

Move two source files + their relevant tests; add the package target. No runtime behavior changes. Rollback = move them back.
