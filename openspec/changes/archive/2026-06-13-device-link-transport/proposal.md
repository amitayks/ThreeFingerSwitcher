## Why

With the pure wire stack complete (DTOs, codec, framing, assembler, encoder, pump), the Mac needs the actual network layer: discover the paired iPhone on the local network, accept a connection, and move `LinkItem`s over it using the pump. This is the Mac's always-on receive anchor (the phone, being suspendable in the background, is the one that wakes the link on a user action). The connection's *logic* — the version handshake and the pump↔channel wiring — is abstracted behind a byte-transport seam so it is unit-tested with a mock loopback, while the unavoidable `Network.framework`/Bonjour glue is isolated and compile-verified (its runtime behavior is verified on-device by the user, like the rest of the app's hardware-dependent code).

## What Changes

- **A `LinkByteTransport` seam** (Core): an abstract bidirectional byte channel (`send(Data)`, an `onReceive`/`onClose` callback pair, `close()`), so the connection logic does not depend on `Network.framework`.
- **A tested `LinkConnection`** (Core) that drives a `LinkPump` over a `LinkByteTransport`: on start it sends a `hello` (local identity + protocol version); on receiving the peer's `hello` it validates version compatibility (refusing an incompatible major) and learns the peer identity; it sends a `LinkItem` by writing the pump's outbound buffers, and surfaces each received `LinkItem` via a callback. Verified end-to-end with a mock loopback transport (handshake, item exchange both directions, version-mismatch refusal, malformed-stream teardown).
- **`NWByteTransport`** (Core): a `LinkByteTransport` backed by an `NWConnection` (a continuous receive loop → `onReceive`; `send` → `connection.send`). Compile-verified; runtime user-verified.
- **`DeviceLinkService`** (Core, `@MainActor`): advertises an `NWListener` over Bonjour (`_tfslink._tcp`, peer-to-peer enabled), accepts incoming connections, wraps each in an `NWByteTransport` + `LinkConnection`, and exposes a received-`LinkItem` callback for the app to wire to the inbound adapter. Start/stop lifecycle. Compile-verified; runtime user-verified.
- **Security is explicitly deferred to `device-link-pairing`.** v1 transport is unauthenticated TCP; the feature opt-in does NOT ship to users until pairing (mutual auth + TLS pinning) lands. This change builds the plumbing and is gated off by default.

## Capabilities

### New Capabilities
- `device-link-transport`: the Mac network layer — a byte-transport seam, the tested `LinkConnection` (version handshake + pump-driven item send/receive over the seam), an `NWConnection`-backed transport, and a Bonjour `NWListener` service that accepts peers and surfaces received items. Discovery + connection lifecycle. Security (TLS/pairing) is a separate change; this layer is gated off until then.

## Impact

- **New:** `Sources/ThreeFingerSwitcher/DeviceLink/LinkByteTransport.swift`, `LinkConnection.swift`, `NWByteTransport.swift`, `DeviceLinkService.swift`; `Tests/ThreeFingerSwitcherTests/LinkConnectionTests.swift`.
- **Modified:** none yet — `DeviceLinkService` is not wired into `AppCoordinator` here (the opt-in + wiring + Info.plist Bonjour/local-network keys are `device-link-hub`). Nothing enables it.
- **Permissions / distribution:** none added in this change (the Info.plist keys + Local Network prompt handling come with the hub wiring). App stays unsandboxed; no new entitlement.
- **Build:** `LinkConnection` + the seam are `swift test`-verified; the `Network.framework` glue compiles under `swift build` (system framework, no MLX). Runtime behavior (real Bonjour discovery, AWDL throughput) is user-verified on devices.
- **Privacy/speed/UX:** privacy — local-network only, no server; but **not yet encrypted** (pairing change adds TLS), so the opt-in stays off; speed — peer-to-peer enabled on the listener for AWDL; UX — none yet (the Hub surfaces it later).
