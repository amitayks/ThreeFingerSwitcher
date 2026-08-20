# Tasks — remove-device-link

- [x] Delete `Sources/ThreeFingerSwitcher/DeviceLink/` (service, transports, handshake, ReceiveHUD, pairing suite)
- [x] Delete `Clipboard/LinkInboundAdapter.swift` + `Clipboard/LinkOutboundAdapter.swift`
- [x] Delete `Hub/HubDevicesPage.swift`
- [x] Delete the vendored `DeviceLinkKit/` package; drop its products from `Package.swift` (Core + test target)
- [x] AppCoordinator: remove the `DeviceLinkProtocol` import, `receiveHUD`, `deviceLinkService`, `pairedDeviceStore`, `macPairingCoordinator`, the adapters, `localDeviceIdentity`, `observeDeviceLinkToggle`/`setDeviceLink`, `receiveLinkItem`, `sendLatestClipboardToDevices`, and the Hub context wiring
- [x] HubView: remove the `.devices` destination (title, sidebar, icon, rail button, detail case) and the Devices context seams
- [x] AppSettings: remove `enableDeviceLink` (property, load, default, key)
- [x] ClipboardEntry: remove `ClipboardOrigin`, `origin`, `isPeer`, `peerDeviceName`; keep legacy decode
- [x] ClipboardBandView: remove `ProvenanceChip` and its key-row use
- [x] ClipboardMonitor: remove `suppressSelfWrite`/`suppressedChangeCount`; simplify `poll()`
- [x] Info.plist: remove `NSLocalNetworkUsageDescription` + `NSBonjourServices`
- [x] Tests: delete the 5 device-link suites, the 3 suppression tests, the `enableDeviceLink` settings test
- [x] Specs: delete the 9 device-link/pairing capability folders; trim `tunable-settings`; replace `clipboard-history` provenance requirements with legacy-compat
- [x] Docs: README capability roster (35 → 26) + Hub sidebar listings; CLAUDE.md cleanup note
- [x] Verify: `swift build` + `swift test` green (777 tests)
