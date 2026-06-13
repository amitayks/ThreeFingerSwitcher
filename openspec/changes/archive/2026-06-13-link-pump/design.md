## Context

`DeviceLinkProtocol` now has the encoder (`FrameStreamEncoder`), codec (`LinkCodec`/`FrameDecoder`), and assembler (`InboundAssembler`). The transport needs them wired together. This change provides that one wiring object so transports don't re-implement it.

## Goals / Non-Goals

**Goals:** one synchronous `LinkPump` composing the existing pieces; a loopback test proving fidelity under arbitrary buffer fragmentation; v6-clean.

**Non-Goals:** async, channels, Network, connection lifecycle, backpressure — all transport concerns (the transport drives the pump and owns I/O).

## Decisions

**D1 — Synchronous `mutating struct`, not an `actor`/async type.** The transport already runs on a connection's serial context and owns the async reads/writes; the pump only translates. A synchronous struct is simpler, avoids actor hops, and is trivially testable. The transport calls `outbound(item)` to get bytes to write and `ingest(bytes)` on each read. *Alternative:* an `actor LinkSession` owning a `ByteChannel` — rejected for v1: it forces an I/O abstraction and async test scaffolding for no benefit while the transport already serializes.

**D2 — `Inbound` is an enum (`.item` / `.control`).** `ingest` can yield zero or more results per call (a buffer may complete several items or none); returning `[Inbound]` lets the caller handle items and pass control frames (hello/ack/error) to the handshake/ack logic.

**D3 — The pump owns its own `FrameDecoder`/`InboundAssembler` instances** (per connection), so two connections never share reassembly state. `outbound` is non-mutating (encoder + codec are stateless); `ingest` mutates the decoder/assembler.

## Risks / Trade-offs

- **A single pump instance is per-connection, single-threaded.** → That matches the transport's per-connection serial context; documented. Concurrency is the transport's job.

## Migration Plan

Additive: one file + tests in the pure package. No API change. Rollback = delete the file.
