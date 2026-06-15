import Foundation

/// The send-side counterpart to `InboundAssembler`: splits a `LinkItem` into the ordered frame sequence
/// `itemBegin → chunk… → itemEnd`, honoring a chunk byte bound so large representations stream. Pure and
/// deterministic (representations in sorted-UTI order, 0-based per-representation sequence numbers), so
/// `encode(item) → InboundAssembler` reconstructs an equal item.
public struct FrameStreamEncoder {
    /// Max bytes per `chunk` frame's representation slice.
    public var chunkByteBound: Int

    public init(chunkByteBound: Int = LinkProtocol.defaultChunkByteBound) {
        self.chunkByteBound = max(1, chunkByteBound)
    }

    /// The ordered frames for an item: one header, then bounded chunks per representation, then a terminator.
    public func frames(for item: LinkItem) -> [Frame] {
        var frames: [Frame] = []

        let manifest = item.representations.mapValues { UInt32($0.count) }
        let header = ItemHeader(messageID: item.messageID,
                                kind: item.kind,
                                manifest: manifest,
                                suggestedName: item.suggestedName,
                                capturedAt: item.capturedAt,
                                origin: item.origin)
        frames.append(.itemBegin(header))

        // Deterministic representation order so output is reproducible and byte-stable.
        for uti in item.representations.keys.sorted() {
            let data = item.representations[uti] ?? Data()
            if data.isEmpty {
                // Emit one empty chunk so the assembler records the (empty) representation and the
                // round-trip preserves it.
                frames.append(.chunk(ChunkFrame(messageID: item.messageID, uti: uti, seq: 0, bytes: Data())))
                continue
            }
            var seq: UInt32 = 0
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkByteBound, data.count)
                let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
                frames.append(.chunk(ChunkFrame(messageID: item.messageID, uti: uti, seq: seq, bytes: slice)))
                seq += 1
                offset = end
            }
        }

        frames.append(.itemEnd(item.messageID))
        return frames
    }
}
