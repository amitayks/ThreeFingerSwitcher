## Context

The iOS side (`ios-qr-pairing`) shows/scans QR + runs the exchange. The Mac mirror lets the Mac show a code a phone scans. Reuses `DeviceLinkPairing` + `PairedDeviceStore`. Network/CoreImage are available in Core (MLX-free), so it compiles under `swift build`; the QR image round-trip is unit-testable on macOS.

## Goals / Non-Goals

**Goals:** a Mac Keychain identity; QR image gen (tested round-trip); a `_tfspair._tcp` listener + host exchange runner pinning into `PairedDeviceStore`; the Hub Show-code surface.

**Non-Goals:** the Mac scanning a phone's QR (the Mac has no camera flow here — it shows; phones scan); the TLS-encrypted data link (the follow-up consuming the pins).

## Decisions

**D1 — Mirror the iOS pairing channel on the Mac.** Same `_tfspair._tcp`, same length-prefixed JSON `PairingMessage`, same host `PairingExchange`. Mac-local types (`MacPairingChannel`/`MacPairingListener`) since the iOS ones live in the app target; the *crypto* is the shared `DeviceLinkPairing`. *Alternative:* a shared channel in `DeviceLinkKit` — possible later, but the channel is thin Network glue and each platform's lifecycle differs; keeping it per-platform is simpler now.

**D2 — Keychain for the Mac long-lived key.** Same `SecItem` API as iOS; the fingerprint is what a peer pins. *Alternative:* a file — rejected (a private key belongs in the Keychain).

**D3 — QR image round-trip is the agent-verifiable test.** `CIQRCodeGenerator` → `NSImage`; decode via `CIDetector(ofType: CIDetectorTypeQRCode)`; assert equal. Runs headless on macOS — a real test of the QR path. The cross-device scan itself is user-verified.

**D4 — The Hub starts the listener only while the code is shown.** Advertising the pairing service is scoped to the Show-code view's lifetime, so the Mac isn't always advertising a pairing endpoint.

## Risks / Trade-offs

- **The cross-device flow is user-verified.** → The crypto is unit-tested (shared), the QR image round-trips (tested), the channel/exchange compile; the actual phone-scans-Mac run is on devices.

## Migration Plan

Additive: new Mac pairing files + a Hub section + the Core dep. Rollback = remove them.
