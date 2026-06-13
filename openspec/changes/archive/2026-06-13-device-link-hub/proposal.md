## Why

All the device-link pieces exist (protocol, pump, transport, inbound/outbound adapters, pairing core) but nothing turns them on or surfaces them. This change wires the Mac side into a usable feature: an opt-in, a Hub **Devices** page, the `AppCoordinator` lifecycle that runs the service and routes received items into the existing clipboard store, an outbound trigger, and the Info.plist keys the local-network/Bonjour APIs require. The opt-in mirrors `keepClipboardHistory` (no gesture relocation, no re-login, immediate effect).

## What Changes

- **`enableDeviceLink` opt-in** in `AppSettings` (default OFF, privacy) — mirrors the `keepClipboardHistory` pattern exactly (declaration + load + `Defaults` + `Keys`).
- **`AppCoordinator` lifecycle.** A toggle observer (mirroring `observeClipboardToggle`) starts the `DeviceLinkService` when the opt-in is on and the app is enabled, and stops it otherwise. Received `LinkItem`s are routed through `LinkInboundAdapter` into `ClipboardStore.insert` (so they appear in the Clipboard band and reuse retention/paste); received files write to the clipboard inbox dir. The local device identity is derived from the host name. An outbound helper sends a `ClipboardEntry` to connected peers via `LinkOutboundAdapter` + `DeviceLinkService.send`.
- **A Hub Devices page** (new `HubDestination.devices`): the opt-in toggle, the list of paired devices (from `PairedDeviceStore`) with a Forget action, a "Send latest clipboard item to my devices" button (the v1 outbound trigger), and honest copy about pairing being completed on-device and the link being local-network-only.
- **Info.plist keys**: `NSLocalNetworkUsageDescription` (the macOS Local Network prompt the unsandboxed app triggers) and `NSBonjourServices` (`_tfslink._tcp`).
- **Still gated on pairing for security.** Per the transport/pairing changes, the wire is not yet TLS-pinned; the Devices page states the link is not encrypted until pairing's TLS follow-up lands, and the opt-in copy reflects that. (The plumbing is complete and compile-verified; turning it on for real is the user's on-device step.)

## Capabilities

### New Capabilities
- `device-link-hub`: the Mac integration surface — the `AppCoordinator` service lifecycle (start/stop on the opt-in; received items → inbound adapter → clipboard store; outbound send), the Hub Devices page (opt-in, paired-device list + forget, outbound trigger), and the Info.plist local-network/Bonjour declarations.

### Modified Capabilities
- `tunable-settings`: adds the `enableDeviceLink` opt-in (default OFF; no gesture relocation, no re-login, no `is…Effective` gate — like `keepClipboardHistory`), persisted and live-applied. Older settings load with it OFF.

## Impact

- **New:** `Sources/ThreeFingerSwitcher/Hub/HubDevicesPage.swift`; `Tests/ThreeFingerSwitcherTests/AppSettingsTests.swift` gains an `enableDeviceLink` persistence test.
- **Modified:** `Settings/AppSettings.swift` (the opt-in), `App/AppCoordinator.swift` (service lifecycle + routing + outbound helper + HubContext wiring), `Hub/HubView.swift` (the `.devices` destination + rail button + page), `Resources/Info.plist` (`NSLocalNetworkUsageDescription`, `NSBonjourServices`).
- **Permissions / distribution:** adds the macOS **Local Network** prompt (first time the service advertises/connects); no entitlement (unsandboxed). No native-gesture relocation, no re-login.
- **Build:** the opt-in is `swift test`-verified; the wiring + page compile under `swift build` (SwiftUI + Network in Core). Real Bonjour discovery + the on-device pairing flow are user-verified.
- **Privacy/speed/UX:** privacy — opt-in default OFF; the page is honest that the link is local-only and (pre-pairing-TLS) not yet encrypted; UX — received items appear in the familiar Clipboard band, tagged "from \<device\>".
