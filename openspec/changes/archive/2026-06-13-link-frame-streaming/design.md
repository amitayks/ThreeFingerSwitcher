## Context

`DeviceLinkProtocol` already has the receive side (`InboundAssembler`) and the codec (`LinkCodec`/`FrameDecoder`). The send side — turning a `LinkItem` into the frame sequence the assembler expects — was deferred. This adds it as the symmetric counterpart, in the same pure package, so the round trip is closed and testable.

## Goals / Non-Goals

**Goals:** a pure, deterministic `LinkItem → [Frame]` encoder with bounded chunking; a round-trip property test against `InboundAssembler`.

**Non-Goals:** anything I/O or Network (the transport `ByteChannel`/session is a later change); resumability/offset-resume (the manifest is forward-compatible with it later).

## Decisions

**D1 — Emit frames as a materialized `[Frame]`, not an async stream.** The encoder returns the full ordered array; the transport iterates and writes each frame's encoded bytes to its channel, applying backpressure at the channel. A materialized array keeps the encoder pure and trivially testable; for very large files the transport can instead drive a chunk-at-a-time variant later (the chunking math is the same). *Alternative:* an `AsyncSequence` of frames — rejected for v1 as harder to test and unnecessary while the transport applies backpressure per write.

**D2 — Deterministic representation order (sorted UTI keys) and 0-based per-representation `seq`.** Makes output reproducible and the assembler's sequence check satisfiable. *Alternative:* dictionary iteration order — rejected (non-deterministic, breaks byte-stable tests).

**D3 — An empty representation emits one empty `chunk`.** Without it the assembler never records the representation (it stays absent from `buffers`), so the round-trip would silently drop empty representations. One zero-byte chunk makes `buffers[uti] = Data()` and the manifest's `0 == 0` validation pass, preserving the representation.

**D4 — Default chunk bound is `LinkProtocol.defaultChunkByteBound` (256 KiB), overridable.** Tests use a tiny bound to force multi-chunk paths.

## Risks / Trade-offs

- **Materializing all frames for a huge file holds them in memory.** → v1 transfers fit; the same chunking math powers a streaming variant when the disk-streaming transport path lands (protocol design D4). Documented, not blocking.

## Migration Plan

Additive: one new file + tests in the existing pure package. No API change. Rollback = delete the file.
