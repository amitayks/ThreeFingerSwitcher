## 1. QR payload

- [x] 1.1 `DeviceLinkKit/Sources/DeviceLinkPairing/PairingQRPayload.swift`: `struct PairingQRPayload` (version, `DeviceIdentity`, `secret: Data`, `spkiFingerprint: Data`); `static func makeSecret()` (32 CSPRNG bytes); `encodedString()` (`tfslink:` + base64url(JSON)); `init(string:) throws` validating scheme/version/fields; a typed `PairingQRError`.

## 2. Exchange

- [x] 2.1 `PairingMessage.swift`: `Codable` enum — `joinerHello(ephemeral, identity, spki)`, `hostHello(ephemeral, identity, spki, confirm)`, `joinerConfirm(confirm)` (X25519 keys carried as raw representation Data).
- [x] 2.2 `PairingExchange.swift`: `enum Role { host, joiner }`, `enum PairingResult { pinned(DeviceIdentity, Data); failed }`; holds an ephemeral X25519 key + the secret + local identity + local SPKI; confirmation key via `HKDF(ECDH, salt: secret, info: v1 ‖ sorted pubkeys)`; `start() -> PairingMessage?` (joiner only); `consume(_:) throws -> (reply: PairingMessage?, result: PairingResult?)` implementing the 3-message flow with HMAC verify → pin.

## 3. Tests (DeviceLinkPairingTests)

- [x] 3.1 Payload: round-trip (identity/secret/fp/version); wrong scheme → throws; bad version → throws; `makeSecret` is 32 bytes.
- [x] 3.2 Exchange: same secret → both pin the other's identity + fingerprint (wire joiner↔host in memory).
- [x] 3.3 MITM: different secrets → confirmation fails, neither pins.
- [x] 3.4 Tamper: flip a byte of a confirmation → the receiver reports failed.

## 4. Verify

- [x] 4.1 `cd DeviceLinkKit && swift test` green (payload + exchange + adversarial); full Mac `swift test` unaffected.
