import Foundation

/// The length-prefixed binary codec. Frame envelope on the wire:
///
///     magic(4) | wireFormatVersion(1) | frameType(1) | length(UInt32 BE) | payload(length)
///
/// Control/header frame bodies (`hello`/`ack`/`error`/`itemBegin`/`itemEnd`/`cancel`) are encoded with
/// a deterministic JSON encoder (small, structural, forward-evolvable). `chunk` bodies are raw bytes
/// with a fixed sub-header — never JSON/base64 — so large transfers stream without inflation.
public enum LinkCodec {
    static let magic: [UInt8] = [0x54, 0x46, 0x53, 0x4C] // "TFSL"
    static let wireFormatVersion: UInt8 = 1
    /// Envelope size: magic(4) + version(1) + type(1) + length(4).
    static let envelopePrefix = 10

    // MARK: Encode

    public static func encode(_ frame: Frame) throws -> Data {
        let (type, payload) = try encodePayload(frame)
        var out = Data()
        out.append(contentsOf: magic)
        out.append(wireFormatVersion)
        out.append(type.rawValue)
        appendU32BE(UInt32(payload.count), to: &out)
        out.append(payload)
        return out
    }

    static func encodePayload(_ frame: Frame) throws -> (FrameType, Data) {
        switch frame {
        case let .hello(identity, version):
            return (.hello, try json.encode(HelloBody(identity: identity, version: version)))
        case let .ack(id):
            return (.ack, try json.encode(IDBody(messageID: id)))
        case let .error(code):
            return (.error, try json.encode(ErrorBody(code: code)))
        case let .itemBegin(header):
            return (.itemBegin, try json.encode(header))
        case let .chunk(chunk):
            return (.chunk, encodeChunk(chunk))
        case let .itemEnd(id):
            return (.itemEnd, try json.encode(IDBody(messageID: id)))
        case let .cancel(id):
            return (.cancel, try json.encode(IDBody(messageID: id)))
        }
    }

    static func encodeChunk(_ chunk: ChunkFrame) -> Data {
        var out = Data()
        out.append(uuidBytes(chunk.messageID))            // 16
        let utiBytes = Array(chunk.uti.utf8)
        appendU16BE(UInt16(utiBytes.count), to: &out)     // 2
        out.append(contentsOf: utiBytes)                  // utiLen
        appendU32BE(chunk.seq, to: &out)                  // 4
        out.append(chunk.bytes)                           // rest
        return out
    }

    // MARK: Decode

    static func decodePayload(type: FrameType, payload: Data) throws -> Frame {
        do {
            switch type {
            case .hello:
                let body = try json.decode(HelloBody.self, from: payload)
                return .hello(body.identity, body.version)
            case .ack:
                return .ack(try json.decode(IDBody.self, from: payload).messageID)
            case .error:
                return .error(try json.decode(ErrorBody.self, from: payload).code)
            case .itemBegin:
                return .itemBegin(try json.decode(ItemHeader.self, from: payload))
            case .chunk:
                return .chunk(try decodeChunk(payload))
            case .itemEnd:
                return .itemEnd(try json.decode(IDBody.self, from: payload).messageID)
            case .cancel:
                return .cancel(try json.decode(IDBody.self, from: payload).messageID)
            }
        } catch let error as LinkProtocolError {
            throw error
        } catch {
            throw LinkProtocolError(.malformedPayload)
        }
    }

    static func decodeChunk(_ payload: Data) throws -> ChunkFrame {
        guard payload.count >= 16 + 2 else { throw LinkProtocolError(.malformedPayload) }
        let messageID = uuid(from: payload, offset: 0)
        let utiLen = Int(u16(payload, 16))
        let utiStart = 18
        guard payload.count >= utiStart + utiLen + 4 else { throw LinkProtocolError(.malformedPayload) }
        let s = payload.startIndex
        let uti = String(decoding: payload[(s + utiStart)..<(s + utiStart + utiLen)], as: UTF8.self)
        let seq = u32(payload, utiStart + utiLen)
        let bytesStart = utiStart + utiLen + 4
        let bytes = Data(payload[(s + bytesStart)...])
        return ChunkFrame(messageID: messageID, uti: uti, seq: seq, bytes: bytes)
    }

    // MARK: Codable bodies (control/header frames)

    static let json: JSONCoder = JSONCoder()

    struct HelloBody: Codable { var identity: DeviceIdentity; var version: ProtocolVersion }
    struct IDBody: Codable { var messageID: UUID }
    struct ErrorBody: Codable { var code: LinkProtocolError.Code }

    // MARK: Byte helpers

    static func appendU16BE(_ v: UInt16, to data: inout Data) {
        data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8(v & 0xff))
    }

    static func appendU32BE(_ v: UInt32, to data: inout Data) {
        data.append(UInt8((v >> 24) & 0xff))
        data.append(UInt8((v >> 16) & 0xff))
        data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8(v & 0xff))
    }

    static func u16(_ d: Data, _ offset: Int) -> UInt16 {
        let s = d.startIndex + offset
        return (UInt16(d[s]) << 8) | UInt16(d[s + 1])
    }

    static func u32(_ d: Data, _ offset: Int) -> UInt32 {
        let s = d.startIndex + offset
        return (UInt32(d[s]) << 24) | (UInt32(d[s + 1]) << 16) | (UInt32(d[s + 2]) << 8) | UInt32(d[s + 3])
    }

    static func uuidBytes(_ uuid: UUID) -> Data {
        var u = uuid.uuid
        return withUnsafeBytes(of: &u) { Data($0) }
    }

    static func uuid(from d: Data, offset: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let s = d.startIndex + offset
        for i in 0..<16 { bytes[i] = d[s + i] }
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}

/// A small deterministic JSON encode/decode pair (sorted keys → reproducible bytes). Wrapped so the
/// codec holds one instance and tests can rely on byte-stable output.
struct JSONCoder {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        self.encoder = e
        self.decoder = JSONDecoder()
    }

    func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }
}

/// A streaming frame splitter. Push bytes as they arrive; pull complete `Frame`s until `next()` returns
/// nil (needs more bytes). Reassembles a frame across multiple reads, enforces a max-frame cap, and
/// throws a typed `LinkProtocolError` on a malformed/oversize stream.
public struct FrameDecoder {
    public var maxFrameLength: Int
    private var buffer = Data()

    public init(maxFrameLength: Int = LinkProtocol.defaultMaxFrameLength) {
        self.maxFrameLength = maxFrameLength
    }

    /// Append newly-received bytes.
    public mutating func push(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame, or nil if more bytes are needed. Throws on a malformed/oversize stream.
    public mutating func next() throws -> Frame? {
        guard buffer.count >= LinkCodec.envelopePrefix else { return nil }
        let s = buffer.startIndex
        for i in 0..<4 where buffer[s + i] != LinkCodec.magic[i] {
            throw LinkProtocolError(.badMagic)
        }
        guard buffer[s + 4] == LinkCodec.wireFormatVersion else {
            throw LinkProtocolError(.unsupportedVersion)
        }
        guard let type = FrameType(rawValue: buffer[s + 5]) else {
            throw LinkProtocolError(.unknownFrameType)
        }
        let length = Int(LinkCodec.u32(buffer, 6))
        guard length <= maxFrameLength else { throw LinkProtocolError(.oversizeLength) }
        let total = LinkCodec.envelopePrefix + length
        guard buffer.count >= total else { return nil } // need more bytes
        let payload = Data(buffer[(s + LinkCodec.envelopePrefix)..<(s + total)])
        buffer = Data(buffer[(s + total)...]) // advance + reset indices
        return try LinkCodec.decodePayload(type: type, payload: payload)
    }

    /// Number of buffered bytes not yet consumed (a partial frame).
    public var bufferedByteCount: Int { buffer.count }

    /// Call when the underlying stream has closed AFTER draining all frames via `next()`. Throws
    /// `.truncatedFrame` if a partial frame remains.
    public func close() throws {
        if !buffer.isEmpty { throw LinkProtocolError(.truncatedFrame) }
    }
}
