## 1. Opt-in (tested)

- [x] 1.1 `AppSettings`: add `enableDeviceLink` (`@Published` + `didSet` persist), the load line, `Defaults.enableDeviceLink = false`, `Keys.enableDeviceLink`.
- [x] 1.2 `AppSettingsTests`: default false; set true + reload reads true.

## 2. AppCoordinator wiring (compile-verified)

- [x] 2.1 Stored props: `deviceLinkService: DeviceLinkService?`, `pairedDeviceStore`, a lazy `LinkInboundAdapter` (inbox under the clipboard dir), a persisted stable device id + a `localDeviceIdentity`.
- [x] 2.2 `observeDeviceLinkToggle()` (mirror `observeClipboardToggle`), called next to it (~line 298); `setDeviceLink(_ on:)` start/stop.
- [x] 2.3 On start: build the service, set `onItem` → adapt → `clipboardStore.insert`; on stop: `stop()` + nil out.
- [x] 2.4 `sendLatestClipboardToDevices()`: most-recent entry → `LinkOutboundAdapter` → `deviceLinkService?.send`.
- [x] 2.5 `makeHubContext`: wire `pairedDevices`, `onForgetDevice`, `onSendLatestToDevices`.

## 3. Hub Devices page (compile-verified)

- [x] 3.1 `HubDestination.devices` (+ title/sidebarTitle/systemImage); rail button + detail case in `HubView`.
- [x] 3.2 `HubContext`: add `pairedDevices: () -> [PairedDevice]`, `onForgetDevice: (String) -> Void`, `onSendLatestToDevices: () -> Void`.
- [x] 3.3 `Hub/HubDevicesPage.swift`: opt-in toggle, paired-device list + Forget, "Send latest clipboard item" button, honest local-only/not-yet-encrypted copy.

## 4. Info.plist

- [x] 4.1 Add `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_tfslink._tcp`) to `Resources/Info.plist`.

## 5. Verify

- [x] 5.1 `swift build --target ThreeFingerSwitcherCore` clean; `swift test` green (settings test + no regressions).
- [ ] 5.2 USER-VERIFIED (device) — pending: the Devices page rendering, the Local Network prompt, and real discovery + receive/send between devices (after the pairing-TLS follow-up). Cannot be verified in the agent shell.
