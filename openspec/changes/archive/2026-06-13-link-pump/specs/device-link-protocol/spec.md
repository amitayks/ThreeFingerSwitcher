## ADDED Requirements

### Requirement: LinkPump bridges items and channel bytes
The protocol SHALL provide a pure, synchronous `LinkPump` that composes the frame encoder, codec, decoder, and inbound assembler. It SHALL expose: encoding a `LinkItem` to the ordered byte buffers to write (one per frame); encoding a single control frame to bytes; ingesting received bytes and returning any completed inbound results (`.item` or `.control`); and a stream-end check that fails on a truncated frame. It SHALL perform no I/O and SHALL surface only typed `LinkProtocolError`s on violations.

#### Scenario: Outbound item becomes per-frame byte buffers
- **WHEN** a `LinkItem` is passed to the pump's outbound encoding
- **THEN** it returns one encoded byte buffer per frame (itemBegin, chunks, itemEnd), each a complete encoded frame

#### Scenario: Ingest returns completed items
- **WHEN** the encoded buffers for an item are ingested
- **THEN** the pump returns exactly one `.item` equal to the original once `itemEnd` is processed

#### Scenario: Protocol violation surfaces a typed error
- **WHEN** malformed bytes are ingested
- **THEN** ingest throws a `LinkProtocolError`, not an untyped error

### Requirement: Loopback fidelity under arbitrary fragmentation
A `LinkItem` encoded by a sender pump and ingested by a receiver pump SHALL reassemble to an equal item regardless of how the encoded bytes are grouped — whether each frame is delivered separately, all frames are concatenated into one buffer, or the byte stream is re-split at arbitrary boundaries.

#### Scenario: Frame-per-buffer delivery
- **WHEN** each outbound buffer is ingested individually
- **THEN** the item reassembles equal to the original

#### Scenario: Concatenated delivery
- **WHEN** all outbound buffers are concatenated into one buffer and ingested at once
- **THEN** the item reassembles equal to the original

#### Scenario: Re-split at arbitrary boundaries
- **WHEN** the concatenated bytes are re-sliced into fixed-size pieces that do not align with frame boundaries and ingested in order
- **THEN** the item reassembles equal to the original
