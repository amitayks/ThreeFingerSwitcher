## 1. Pump

- [x] 1.1 `Sources/DeviceLinkProtocol/LinkPump.swift`: `struct LinkPump` owning a `FrameStreamEncoder`, `FrameDecoder`, `InboundAssembler`; `enum Inbound: Equatable, Sendable { case item(LinkItem); case control(Frame) }`.
- [x] 1.2 `outbound(_ item:) throws -> [Data]` (frames → encoded buffers); `outbound(control:) throws -> Data`.
- [x] 1.3 `mutating func ingest(_ data:) throws -> [Inbound]` (push → drain decoder → assemble); `func finish() throws` (decoder close / truncation check).

## 2. Tests

- [x] 2.1 Outbound returns one buffer per frame; ingest of those buffers yields one `.item` equal to the original.
- [x] 2.2 Loopback frame-per-buffer, concatenated, and re-split-at-arbitrary-boundaries all reassemble equal (multi-rep, multi-chunk item with a small chunk bound).
- [x] 2.3 Malformed bytes → `ingest` throws a `LinkProtocolError`; truncated stream → `finish` throws.
- [x] 2.4 Control frame round-trips as `.control`.

## 3. Verify

- [x] 3.1 `swift test --filter DeviceLinkProtocolTests` green; full `swift test` no regressions.
