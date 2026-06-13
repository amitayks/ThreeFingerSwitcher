## 1. Transport seam + connection logic (tested)

- [x] 1.1 `DeviceLink/LinkByteTransport.swift`: protocol with `send(_ Data)`, `var onReceive: ((Data) -> Void)?`, `var onClose: ((Error?) -> Void)?`, `close()`.
- [x] 1.2 `DeviceLink/LinkConnection.swift`: `final class LinkConnection` holding a `LinkPump`, a transport, and a local `DeviceIdentity`; `start()` sends `hello`; `send(_ LinkItem)` writes pump outbound buffers; received bytes → `pump.ingest` → `onItem` for items, handshake for `.hello` (version check + learn peer), teardown on thrown `LinkProtocolError`. Callbacks: `onItem`, `onHandshake(DeviceIdentity)`, `onError`.

## 2. Network glue (compile-verified)

- [x] 2.1 `DeviceLink/NWByteTransport.swift`: `LinkByteTransport` over an `NWConnection` — continuous `receive` loop → `onReceive`; `send` → `connection.send`; state/close → `onClose`; `start(queue:)`.
- [x] 2.2 `DeviceLink/DeviceLinkService.swift`: `@MainActor final class` advertising an `NWListener` (`_tfslink._tcp`, `NWParameters` with `includePeerToPeer = true`), `newConnectionHandler` → wrap in `NWByteTransport` + `LinkConnection`, dispatch received items to `@MainActor onItem`; `start() throws` / `stop()`.

## 3. Tests (mock loopback)

- [x] 3.1 `Tests/.../LinkConnectionTests.swift`: `MockByteTransport.pair()` (each `send` delivers to the peer's `onReceive`).
- [x] 3.2 Both connections start → each learns the other's identity (handshake).
- [x] 3.3 Item sent A→B (and B→A) arrives equal via `onItem`.
- [x] 3.4 Incompatible-major `hello` → `onError` + close, no item surfaced.
- [x] 3.5 Malformed bytes injected → `onError` with a `LinkProtocolError` + transport closed.

## 4. Verify

- [x] 4.1 `swift build --target ThreeFingerSwitcherCore` clean (Network glue compiles); `swift test` green (connection tests + no regressions).
- [ ] 4.2 USER-VERIFIED (device) — pending: real Bonjour discovery, accept, and item receipt between two machines/devices, once pairing + hub wiring land. (Cannot be verified in the agent shell; deferred to the user, like all on-device behavior.)
