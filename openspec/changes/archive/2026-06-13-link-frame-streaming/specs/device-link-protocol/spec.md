## ADDED Requirements

### Requirement: Outbound frame-stream encoding
The protocol SHALL provide a pure `FrameStreamEncoder` that maps a `LinkItem` to an ordered sequence of frames: exactly one `itemBegin` (carrying the item's kind and a manifest of every representation's UTI → total byte length, plus the item's metadata), then, per representation, one or more `chunk` frames whose bytes concatenate to that representation, then exactly one `itemEnd`. No `chunk` SHALL exceed the encoder's configurable chunk byte bound. Representations SHALL be emitted in a deterministic order and each representation's chunks SHALL carry 0-based, consecutive sequence numbers. The encoder SHALL perform no I/O.

#### Scenario: A small item encodes to begin, one chunk, end
- **WHEN** a `LinkItem` with a single representation smaller than the chunk bound is encoded
- **THEN** the result is exactly `[itemBegin, chunk(seq 0), itemEnd]`, the header manifest lists that representation's byte length, and the chunk's bytes equal the representation

#### Scenario: A large representation is split into bounded chunks
- **WHEN** a representation larger than the chunk bound is encoded with bound B
- **THEN** it is emitted as ceil(size/B) `chunk` frames with consecutive sequence numbers, each at most B bytes, concatenating back to the representation

#### Scenario: Deterministic output
- **WHEN** the same `LinkItem` is encoded twice
- **THEN** the two frame sequences are identical (stable representation order and sequence numbers)

### Requirement: Encode/decode round-trip fidelity
A `LinkItem` encoded by `FrameStreamEncoder` and fed frame-by-frame into `InboundAssembler` SHALL reassemble to an equal `LinkItem` (same kind, representations, and metadata), including items with multiple representations of mixed sizes, multi-chunk representations, and empty representations.

#### Scenario: Multi-representation round-trip
- **WHEN** an item with several representations of different sizes (some larger than the chunk bound) is encoded and reassembled
- **THEN** the reassembled item equals the original

#### Scenario: Empty representation survives the round-trip
- **WHEN** an item containing a zero-byte representation is encoded and reassembled
- **THEN** the reassembled item still contains that representation (as empty), equal to the original
