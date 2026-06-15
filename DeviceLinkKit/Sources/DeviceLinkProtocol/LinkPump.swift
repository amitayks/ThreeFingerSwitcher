import Foundation

/// The single synchronous bridge between `LinkItem`s and the raw bytes on a channel. Composes the
/// frame encoder, codec, decoder, and inbound assembler so a transport never re-wires them: call
/// `outbound(_:)` to get the byte buffers to write, and `ingest(_:)` on each received buffer to get
/// back completed items / control frames. Pure (no I/O); the transport owns the async channel and its
/// own serial context, so the pump is a plain `mutating struct`, one per connection.
public struct LinkPump {
    private let encoder: FrameStreamEncoder
    private var decoder: FrameDecoder
    private var assembler: InboundAssembler

    /// A completed inbound result from `ingest`.
    public enum Inbound: Equatable, Sendable {
        case item(LinkItem)
        case control(Frame)   // hello / ack / error — for the transport's handshake/ack logic
    }

    public init(chunkByteBound: Int = LinkProtocol.defaultChunkByteBound,
                maxFrameLength: Int = LinkProtocol.defaultMaxFrameLength) {
        self.encoder = FrameStreamEncoder(chunkByteBound: chunkByteBound)
        self.decoder = FrameDecoder(maxFrameLength: maxFrameLength)
        self.assembler = InboundAssembler()
    }

    // MARK: Outbound

    /// The ordered encoded byte buffers for an item (one complete encoded frame each).
    public func outbound(_ item: LinkItem) throws -> [Data] {
        try encoder.frames(for: item).map { try LinkCodec.encode($0) }
    }

    /// Encode a single control frame (hello/ack/error) to bytes.
    public func outbound(control frame: Frame) throws -> Data {
        try LinkCodec.encode(frame)
    }

    // MARK: Inbound

    /// Push received bytes; return any completed inbound results. Throws a typed `LinkProtocolError`
    /// on a malformed/violating stream.
    public mutating func ingest(_ data: Data) throws -> [Inbound] {
        decoder.push(data)
        var out: [Inbound] = []
        while let frame = try decoder.next() {
            switch try assembler.consume(frame) {
            case .item(let item):  out.append(.item(item))
            case .control(let f):  out.append(.control(f))
            case .none:            break
            }
        }
        return out
    }

    /// Assert the stream ended cleanly (no partial frame buffered). Throws `.truncatedFrame` otherwise.
    public func finish() throws {
        try decoder.close()
    }
}
