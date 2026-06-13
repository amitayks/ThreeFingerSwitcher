## MODIFIED Requirements

### Requirement: Code-authenticated key agreement
Two parties, each with an ephemeral X25519 key pair, SHALL derive a shared confirmation key from the ECDH shared secret, the pairing code, and both public keys, such that both sides compute the **same** confirmation key when (and only when) they used the **same** code. The derivation SHALL be role-independent (the same key regardless of which side is initiator). Confirmation SHALL be by an exchanged HMAC over the agreed key; matching confirmations prove both sides knew the code. The implementation SHALL live in the shared `DeviceLinkPairing` package so the Mac and the iOS app use one tested copy.

#### Scenario: Same code, both sides agree
- **WHEN** two parties run the handshake with each other's public key and the same code
- **THEN** both derive confirmation values that match, so each accepts the other

#### Scenario: Different code defeats a man-in-the-middle
- **WHEN** the two parties used different codes (as an active MITM relaying keys would force)
- **THEN** their confirmation values do not match, so confirmation fails and pairing is rejected

#### Scenario: Shared package hosts the crypto
- **WHEN** either the Mac or the iOS app performs pairing
- **THEN** it uses the `PairingHandshake`/`PairingCode` from the shared `DeviceLinkPairing` package (not a per-platform copy)
