## 1. Encoder

- [x] 1.1 `Sources/DeviceLinkProtocol/FrameStreamEncoder.swift`: `struct FrameStreamEncoder { var chunkByteBound }` with `func frames(for: LinkItem) -> [Frame]`.
- [x] 1.2 Build the `itemBegin` header from the item (kind + manifest of UTI→total bytes + metadata).
- [x] 1.3 For each representation in sorted-UTI order, emit bounded `chunk` frames (≤ bound, 0-based consecutive `seq`); an empty representation emits one empty chunk; then a final `itemEnd`.

## 2. Tests

- [x] 2.1 Small single-rep item → `[itemBegin, chunk(seq 0), itemEnd]`; header manifest correct; chunk bytes equal the rep.
- [x] 2.2 Large rep with a tiny bound → ceil(size/B) chunks, consecutive seq, each ≤ B, concatenating back.
- [x] 2.3 Determinism: encoding the same item twice yields identical frames.
- [x] 2.4 Round-trip: encode → feed every frame to `InboundAssembler` → reassembled item equals original, for (a) multi-rep mixed sizes incl. >bound, (b) an item with a zero-byte representation.

## 3. Verify

- [x] 3.1 `swift build --target DeviceLinkProtocol` clean; `swift test --filter DeviceLinkProtocolTests` green; full `swift test` no regressions.
