## Context

The pure stack (`LinkPump` et al.) handles all wire logic. What remains is network I/O: discovery, connection, and lifecycle. Per the workflow research, the Mac is the always-on anchor (the iOS app is suspendable in the background, so it wakes the link on a user action). `ThreeFingerSwitcherCore` is MLX-free and may use `Network.framework` (a system framework), so the glue compiles under `swift build`; its runtime behavior is user-verified on devices, consistent with how the app's other hardware/OS-dependent code is verified.

## Goals / Non-Goals

**Goals:** a transport seam that keeps the connection logic testable; a tested `LinkConnection`; an `NWConnection`/Bonjour service that's compile-verified and structured for the hub change to wire up.

**Non-Goals:** TLS/pairing/auth (`device-link-pairing`); the opt-in + `AppCoordinator` wiring + Info.plist keys (`device-link-hub`); QUIC multi-stream HoL-avoidance (a later optimization); the iOS side (its own changes).

## Decisions

**D1 — Abstract `LinkByteTransport`, concrete `NWByteTransport`.** The connection logic (handshake, pump wiring, item sink) depends only on a `send/onReceive/onClose/close` seam, so a `MockByteTransport` loopback drives it in unit tests; `NWByteTransport` adapts an `NWConnection`. This is the same "pure logic behind a seam" pattern the app uses for the `LLMRuntime` and file workspace. *Alternative:* test against a real local socket — rejected (slow, flaky, not a unit test).

**D2 — Classic `Network.framework` (NWListener/NWConnection/NWBrowser), not the iOS/macOS-26 declarative API, for v1.** The classic API is stable since macOS 10.14 and compiles reliably against the deployment floor (macOS 15); the declarative `NetworkConnection`/QUIC API is macOS-26-only with known compile sharp edges (per the research: must iterate `stream.messages`, not the tunnel). v1 uses a single TCP `NWConnection` with `includePeerToPeer = true`; the pump's `messageID` interleaving gives logical small-ahead-of-large ordering. QUIC multi-stream (physical HoL avoidance) is a documented later optimization. *Alternative:* declarative QUIC now — deferred to avoid bleeding-edge compile risk on un-runtime-testable code.

**D3 — Threading: everything runs on the service's serial `DispatchQueue`; only the final item delivery hops to `@MainActor`.** `NWConnection` callbacks fire on that queue; `LinkConnection` is driven entirely from it (no cross-thread pump access), and `DeviceLinkService.onItem` is dispatched to `@MainActor` for the app (the inbound adapter + `ClipboardStore` are `@MainActor`). The unit tests drive `LinkConnection` synchronously via the mock, so they don't exercise the queue.

**D4 — Security deferred, feature gated off.** v1 is unauthenticated TCP. The opt-in does not ship until `device-link-pairing` adds a pinned TLS identity + the code handshake. This change ships dark (nothing constructs `DeviceLinkService` yet).

## Risks / Trade-offs

- **Unauthenticated v1 transport.** → Gated off; pairing is the immediate next change; documented that the opt-in must not enable until pairing lands.
- **Network glue is not unit-tested.** → The risky *logic* (handshake, framing) is behind the seam and IS tested; the glue is thin and compile-verified, runtime-verified by the user on devices.
- **Receive loop / backpressure correctness only verifiable on-device.** → Keep the `NWByteTransport` loop minimal and standard (`receive(min:max:)` re-arm); note as a user-verify task.

## Migration Plan

Additive: a new `DeviceLink/` folder in Core + tests. Nothing references `DeviceLinkService` yet, so no runtime change. Rollback = delete the folder.

## Open Questions

- QUIC multi-stream vs single TCP: revisit after on-device throughput measurement (the hub/pairing changes can switch the `NWParameters` without touching `LinkConnection`).
- Reconnection/keep-warm policy lives with the service; the initial version accepts-on-demand and the hub change decides advertise-always vs on-toggle.
