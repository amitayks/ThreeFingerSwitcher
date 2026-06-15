import Foundation

/// The header that opens an item: its kind, the per-representation byte manifest (UTI → total bytes,
/// so the receiver knows the full size before any bytes arrive), and optional metadata. `Codable` —
/// encoded as a control body by the codec.
public struct ItemHeader: Equatable, Sendable, Codable {
    public var messageID: UUID
    public var kind: LinkItemKind
    public var manifest: [String: UInt32]
    public var suggestedName: String?
    public var capturedAt: Date?
    public var origin: DeviceIdentity?

    public init(messageID: UUID,
                kind: LinkItemKind,
                manifest: [String: UInt32],
                suggestedName: String? = nil,
                capturedAt: Date? = nil,
                origin: DeviceIdentity? = nil) {
        self.messageID = messageID
        self.kind = kind
        self.manifest = manifest
        self.suggestedName = suggestedName
        self.capturedAt = capturedAt
        self.origin = origin
    }
}

/// One bounded slice of one representation's bytes. Hand-encoded as raw bytes (never JSON/base64) so a
/// large file streams without inflation. `seq` is the 0-based, per-representation chunk index.
public struct ChunkFrame: Equatable, Sendable {
    public var messageID: UUID
    public var uti: String
    public var seq: UInt32
    public var bytes: Data

    public init(messageID: UUID, uti: String, seq: UInt32, bytes: Data) {
        self.messageID = messageID
        self.uti = uti
        self.seq = seq
        self.bytes = bytes
    }
}

/// The closed set of wire frames. Item-bearing frames carry their `messageID` so frames for different
/// items can be interleaved on a single stream.
public enum Frame: Equatable, Sendable {
    case hello(DeviceIdentity, ProtocolVersion)
    case ack(UUID)
    case error(LinkProtocolError.Code)
    case itemBegin(ItemHeader)
    case chunk(ChunkFrame)
    case itemEnd(UUID)
    case cancel(UUID)

    /// The message id this frame belongs to, when it is item-scoped (nil for `hello`/`error`).
    public var messageID: UUID? {
        switch self {
        case .hello, .error:
            return nil
        case let .ack(id), let .itemEnd(id), let .cancel(id):
            return id
        case let .itemBegin(header):
            return header.messageID
        case let .chunk(chunk):
            return chunk.messageID
        }
    }
}

/// The 1-byte wire tag for each frame type (written in the envelope). Internal to the codec.
enum FrameType: UInt8 {
    case hello = 1
    case ack = 2
    case error = 3
    case itemBegin = 4
    case chunk = 5
    case itemEnd = 6
    case cancel = 7
}
