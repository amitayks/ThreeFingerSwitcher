## Why

The transport (a later, device-dependent change) needs exactly one object that bridges `LinkItem`s and the raw bytes on a channel: encode an item to the bytes to write, and turn received bytes back into items. Rather than scatter `FrameStreamEncoder` + `LinkCodec` + `FrameDecoder` + `InboundAssembler` wiring across each transport, the protocol package SHALL expose a single **synchronous `LinkPump`** that composes them. Keeping it pure and synchronous (the transport owns the async I/O) makes the entire encode→codec→decode→assemble stack provable end-to-end by a loopback test, and lets the Mac transport and the iOS app reuse identical wiring.

## What Changes

- **A pure, synchronous `LinkPump` in `DeviceLinkProtocol`** composing the existing encoder/codec/decoder/assembler:
  - `outbound(_ item:) throws -> [Data]` — the encoded byte buffers (one per frame) to write to the channel.
  - `outbound(control:) throws -> Data` — encode a single control frame (hello/ack/error).
  - `ingest(_ data:) throws -> [Inbound]` — push received bytes; return any completed `.item` / `.control` results; throw a typed `LinkProtocolError` on a violation.
  - `finish() throws` — assert the stream ended cleanly (no truncated frame).
- **A loopback round-trip guarantee.** Feeding a sender pump's `outbound(item)` buffers into a receiver pump's `ingest` reconstructs the item — across multiple representations, multi-chunk payloads, and arbitrary buffer re-splitting (the byte buffers may be concatenated or fragmented and still reassemble).
- **No async, no Network, no actor.** A `mutating struct` of `Sendable` parts; the transport drives the I/O and calls the pump for translation only.

## Capabilities

### Modified Capabilities
- `device-link-protocol`: adds `LinkPump`, the single synchronous bridge between `LinkItem`s and channel bytes (compose of the existing encoder/codec/decoder/assembler), with end-to-end loopback fidelity under arbitrary buffer fragmentation. Additive; no existing requirement changes.

## Impact

- **New:** `Sources/DeviceLinkProtocol/LinkPump.swift`; `Tests/DeviceLinkProtocolTests/LinkPumpTests.swift`.
- **Modified:** none.
- **Build/permissions:** pure logic, MLX/Network-free fast loop; no dependency/permission/distribution impact.
- **Privacy/speed/UX:** none directly (substrate); enables the transport's streaming.
