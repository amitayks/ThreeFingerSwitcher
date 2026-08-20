# Proposal — Remove the device link (iPhone↔Mac pairing + clipboard/file bridge)

## Why

The great cleanup (`remove-local-ai`) refocused the app on the **switcher, the launcher, and clipboard history** — and explicitly kept the device link. On reflection it goes too: remote device syncing is the same kind of drift from the app's intent as the AI stack was. It carries a vendored cross-platform package (`DeviceLinkKit`), a local-network listener + Bonjour advertising (and the macOS Local Network permission that comes with them), QR-pairing crypto, a Hub page, and nine spec capabilities — for a bridge to an iOS companion app that never shipped.

The full-featured app remains preserved on the **`v1` branch** and the **`v1.0.0` release tag**.

## What Changes

**Removed outright (code, tests, specs):**

- **The link runtime:** `Sources/ThreeFingerSwitcher/DeviceLink/` — `DeviceLinkService`, the transport stack (`LinkByteTransport`/`NWByteTransport`/`SealingByteTransport`), `LinkConnection`, `LinkHandshake`, the `ReceiveHUD`, and the pairing suite (`MacPairingCoordinator`/`MacPairingChannel`/`MacLocalIdentity`/`PairedDevice`/`PairedDeviceStore`/`QRImage`).
- **The clipboard adapters:** `LinkInboundAdapter` (LinkItem → ClipboardEntry + the `inbox/` file landing) and `LinkOutboundAdapter`, plus the coordinator's receive/auto-paste/send-latest paths and the `ClipboardMonitor.suppressSelfWrite` seam (its only production caller was the receive path).
- **The vendored package:** `DeviceLinkKit/` (DeviceLinkProtocol / DeviceLinkPairing / DeviceLinkMirror) and its products from `Package.swift`.
- **The Hub Devices page:** `HubDevicesPage`, the `.devices` destination/rail button, and the `pairedDevices`/`onForgetDevice`/`onSendLatestToDevices`/`pairingCoordinator` context seams.
- **Settings:** the `enableDeviceLink` opt-in (property, default, key, observer, test).
- **Clipboard provenance:** `ClipboardOrigin` and `ClipboardEntry.origin`/`isPeer`/`peerDeviceName`, and the band's `ProvenanceChip` — nothing can produce a `.peer` entry any more. A legacy persisted index carrying an `origin` key still decodes (unknown JSON keys are ignored); old peer entries simply behave as local copies.
- **Info.plist:** `NSLocalNetworkUsageDescription` and the `NSBonjourServices` types (`_tfslink._tcp`, `_tfspair._tcp`) — the app no longer touches the local network.
- **Specs:** the 8 `device-link-*` capability folders + `mac-qr-pairing` are deleted; `tunable-settings` drops the device-link opt-in requirement; `clipboard-history` replaces the two provenance requirements with a legacy-index-compatibility requirement. The archive is untouched (design history).
- **Tests:** `LinkConnectionTests`, `LinkInboundAdapterTests`, `LinkOutboundAdapterTests`, `PairingHandshakeTests`, `QRImageTests`, the three self-write-suppression tests, and the `enableDeviceLink` settings test.

## Impact

- `swift build` + `swift test` green: 777 tests (was 805; the deleted suites were device-link-only).
- No behavior change to the keepers. Clipboard capture, band, paste, retention, and exclusions are untouched; the only clipboard delta is that received-from-phone entries can no longer exist.
- Stale UserDefaults keys (`enableDeviceLink`, `deviceLinkLocalID`) are left in place, harmless, per the cleanup convention. A previously granted Local Network permission simply goes unused.
- The `Sources/ThreeFingerSwitcher/KeyboardLanguage/`-style Core-only layout is preserved — everything removed was Core, so no signing/TCC implications.
