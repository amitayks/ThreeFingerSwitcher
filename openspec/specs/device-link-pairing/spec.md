# device-link-pairing Specification

## Purpose
TBD - created by archiving change device-link-pairing. Update Purpose after archive.
## Requirements
### Requirement: High-entropy pairing code
The system SHALL generate a pairing code from a cryptographically-secure random source with at least ~27 bits of entropy (default 8 decimal digits). The code SHALL never be transmitted over the link and SHALL never be used directly as an encryption key. The system SHALL validate a code's format.

#### Scenario: Generated code has the requested length and is numeric
- **WHEN** a pairing code is generated with the default length
- **THEN** it is 8 decimal digits

#### Scenario: Code format validation
- **WHEN** a candidate string is checked
- **THEN** it is accepted only if it is the expected number of decimal digits

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

### Requirement: Pinned-peer trust store
Successful pairing SHALL persist a durable trust record for the peer: its identity and a pinned public-key (SPKI) hash, so subsequent sessions authenticate the peer by pin without the code. The store SHALL support adding, removing, listing, and testing whether a given SPKI hash is pinned, and SHALL be persisted to an injectable location.

#### Scenario: A paired peer is pinned and recognized
- **WHEN** a peer is paired and its SPKI hash recorded, then the store is reloaded
- **THEN** the store reports that SPKI hash as pinned and lists the peer

#### Scenario: An unknown peer is not pinned
- **WHEN** an SPKI hash that was never paired is tested
- **THEN** the store reports it as not pinned

#### Scenario: Unpairing removes the pin
- **WHEN** a paired peer is removed
- **THEN** its SPKI hash is no longer reported as pinned and it is not listed

