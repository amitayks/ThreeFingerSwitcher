## Why

The protocol package (change `device-link-protocol`) defined the receive side — `InboundAssembler` turns a frame stream back into a `LinkItem`. The symmetric **send side** is still missing: a sender needs a pure, deterministic way to split a `LinkItem` into the `itemBegin` → `chunk`s → `itemEnd` frame sequence, honoring the chunk byte bound so large representations stream. Keeping this in the pure, dependency-free package (alongside the assembler) lets the encode↔decode loop be closed by a single round-trip property test, and lets both the Mac transport and the iOS app reuse one encoder. It belongs here, not in the Network transport, because it is pure logic with no I/O.

## What Changes

- **A pure `FrameStreamEncoder` in `DeviceLinkProtocol`** that maps a `LinkItem` to an ordered `[Frame]`: one `itemBegin` carrying the per-representation byte manifest, then, for each representation (in a **deterministic** UTI order), a sequence of bounded `chunk` frames (no chunk larger than the configurable `chunkByteBound`), then one `itemEnd`. An empty representation still emits one empty `chunk` so it survives the round trip.
- **Round-trip closure.** `FrameStreamEncoder(item) → InboundAssembler` reconstructs an equal `LinkItem`, including multi-chunk representations, mixed sizes, and empty representations. This is the property the protocol's correctness rests on.
- **Deterministic output** (sorted representation order, 0-based per-representation sequence) so the encoder is unit-testable byte-for-byte and reproducible across devices.

## Capabilities

### Modified Capabilities
- `device-link-protocol`: adds the outbound `FrameStreamEncoder` (the send-side counterpart to `InboundAssembler`) — `LinkItem` → ordered frame sequence with bounded chunking and round-trip fidelity. No existing requirement changes; this is additive within the same capability.

## Impact

- **New:** `Sources/DeviceLinkProtocol/FrameStreamEncoder.swift`; `Tests/DeviceLinkProtocolTests/FrameStreamEncoderTests.swift`.
- **Modified:** none beyond the new file (no API changes to existing protocol types).
- **Build/permissions:** pure logic in the MLX-free fast loop (`swift test`); no dependency, permission, or distribution impact.
- **Privacy/speed/UX:** speed — the bounded chunking is what lets a large file stream without buffering whole; no privacy/UX surface.
