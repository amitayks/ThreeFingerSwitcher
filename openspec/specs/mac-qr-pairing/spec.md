# mac-qr-pairing Specification

## Purpose
TBD - created by archiving change mac-qr-pairing. Update Purpose after archive.
## Requirements
### Requirement: Mac long-lived identity and QR image
The Mac SHALL maintain a long-lived Curve25519 key in the Keychain + its SHA-256 fingerprint, and SHALL generate a scannable QR `NSImage` from a string. QR generation SHALL round-trip (a generated QR decodes back to the original string).

#### Scenario: QR round-trips
- **WHEN** a string is rendered to a QR image and that image is decoded
- **THEN** the decoded string equals the original

#### Scenario: Identity persists
- **WHEN** the Mac identity is requested across launches
- **THEN** the same key + fingerprint are returned

### Requirement: Mac shows a code and accepts a scanner
The Mac SHALL present its pairing QR (its `PairingQRPayload`) on the Hub Devices page and, while shown, advertise a dedicated pairing service and accept a connection, running the host side of the `PairingExchange`. On success it SHALL pin the scanner into `PairedDeviceStore`; on failure it SHALL pin nothing.

#### Scenario: A scan pairs the new device
- **WHEN** a device scans the Mac's code and the exchange succeeds
- **THEN** the device is added to `PairedDeviceStore` and appears in the Hub's paired list

#### Scenario: A failed exchange pins nothing
- **WHEN** the exchange fails
- **THEN** no device is added

