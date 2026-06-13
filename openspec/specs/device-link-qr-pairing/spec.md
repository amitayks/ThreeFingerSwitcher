# device-link-qr-pairing Specification

## Purpose
TBD - created by archiving change device-link-qr-pairing. Update Purpose after archive.
## Requirements
### Requirement: QR pairing payload
The system SHALL define a versioned `PairingQRPayload` carrying the device identity, a high-entropy pairing secret (at least 32 bytes from a CSPRNG), and the device's long-lived public-key (SPKI) fingerprint. It SHALL encode to a compact string (a `tfslink:` scheme + base64url body) and decode back losslessly, rejecting a wrong scheme, an unsupported version, or missing fields. The secret SHALL never be derived from anything guessable.

#### Scenario: Payload round-trips
- **WHEN** a payload is encoded to its string and decoded back
- **THEN** the decoded payload equals the original (identity, secret, fingerprint, version)

#### Scenario: Malformed string is rejected
- **WHEN** a string with the wrong scheme or an unsupported version is decoded
- **THEN** decoding fails with a typed error rather than producing a payload

### Requirement: Authenticated pairing exchange
The system SHALL provide a pure `PairingExchange` state machine with two roles (host = showed the QR, joiner = scanned it) that exchange `PairingMessage`s. Using the QR secret to authenticate an ephemeral X25519 agreement (confirmation key = `HKDF(ECDH shared secret, salt: secret)`), the parties SHALL exchange and verify HMAC confirmations and, on success, each SHALL pin the other's long-lived public-key fingerprint and identity. The machine SHALL perform no I/O; a transport carries the messages.

#### Scenario: Matching secret → mutual pinning
- **WHEN** a host and a joiner run the exchange with the same QR secret
- **THEN** the joiner ends pinned to the host's identity + fingerprint, and the host ends pinned to the joiner's, each verifying the other's confirmation

#### Scenario: Wrong secret defeats a man-in-the-middle
- **WHEN** the two run the exchange with different secrets (as an attacker who could not read the QR would force)
- **THEN** confirmation verification fails and neither side pins the other

#### Scenario: Tampered confirmation fails
- **WHEN** a confirmation message is altered in transit
- **THEN** the receiving side reports failure and does not pin

#### Scenario: No I/O
- **WHEN** the exchange runs
- **THEN** it produces and consumes `PairingMessage` values only, performing no networking itself

