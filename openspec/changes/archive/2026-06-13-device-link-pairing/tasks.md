## 1. Pairing code

- [x] 1.1 `DeviceLink/Pairing/PairingCode.swift`: `generate(digits: Int = 8) -> String` from a CSPRNG; `isValid(_:digits:) -> Bool`.

## 2. Handshake (CryptoKit)

- [x] 2.1 `DeviceLink/Pairing/PairingHandshake.swift`: holds an ephemeral `Curve25519.KeyAgreement.PrivateKey`; exposes `publicKey`.
- [x] 2.2 `confirmationKey(peerPublicKey:code:) throws -> SymmetricKey` = HKDF-SHA256 over the ECDH shared secret, salt = code bytes, info = `"device-link-pairing-v1"` ‖ sorted(pkSelf, pkPeer).
- [x] 2.3 `confirmation(_ key:label:) -> Data` = HMAC-SHA256(label, key); `verify(_:key:label:) -> Bool` constant-time-ish compare.

## 3. Pinned-peer store

- [x] 3.1 `DeviceLink/Pairing/PairedDevice.swift`: `Codable`/`Equatable` { id, name, pinnedSPKIHash: Data, pairedAt: Date }.
- [x] 3.2 `DeviceLink/Pairing/PairedDeviceStore.swift`: Codable-file store at an injectable dir; `add/remove/all/isPinned(spkiHash:)`; load/save.

## 4. Tests

- [x] 4.1 `PairingCode`: generated length/format; `isValid` accepts 8 digits, rejects wrong length / non-digits.
- [x] 4.2 Handshake: same code → both sides' confirmations match (mutual accept).
- [x] 4.3 MITM: different codes → confirmations DO NOT match (rejected). Also: a relayed-key attacker with a guessed-wrong code fails.
- [x] 4.4 Determinism/role-independence: initiator and responder derive the same confirmation key.
- [x] 4.5 Store: add → reload → `isPinned` true + listed; unknown hash → false; remove → false + unlisted.

## 5. Verify

- [x] 5.1 `swift build --target ThreeFingerSwitcherCore` clean; `swift test` green (pairing tests + no regressions).
- [ ] 5.2 FOLLOW-UP (separate change, user-verified on-device): TLS verify-block pinning + Keychain/Secure-Enclave identity + the on-device pairing flow. Out of scope here by design.
