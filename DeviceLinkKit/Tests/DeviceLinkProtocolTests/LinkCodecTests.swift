import XCTest
@testable import DeviceLinkProtocol

/// Codec contract: round-trip every frame, reassemble across reads, preserve trailing bytes, and reject
/// bad-magic / unknown-tag / oversize / truncated streams with the right typed error.
final class LinkCodecTests: XCTestCase {

    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func allFrames() -> [Frame] {
        [
            .hello(DeviceIdentity(id: "device-1", name: "Amit's Mac"), ProtocolVersion(major: 1, minor: 0)),
            .ack(id),
            .error(.manifestMismatch),
            .itemBegin(ItemHeader(messageID: id, kind: .text,
                                  manifest: [LinkUTI.plainText: 5],
                                  suggestedName: "note.txt",
                                  capturedAt: nil,
                                  origin: DeviceIdentity(id: "device-2", name: "iPhone"))),
            .chunk(ChunkFrame(messageID: id, uti: LinkUTI.plainText, seq: 0, bytes: Data("hello".utf8))),
            .itemEnd(id),
            .cancel(id),
        ]
    }

    /// Build a raw envelope by hand, for the adversarial (malformed) cases.
    private func rawEnvelope(type: UInt8,
                             declaredLength: UInt32,
                             payload: Data = Data(),
                             magic: [UInt8] = LinkCodec.magic,
                             version: UInt8 = LinkCodec.wireFormatVersion) -> Data {
        var d = Data(magic)
        d.append(version)
        d.append(type)
        d.append(UInt8((declaredLength >> 24) & 0xff))
        d.append(UInt8((declaredLength >> 16) & 0xff))
        d.append(UInt8((declaredLength >> 8) & 0xff))
        d.append(UInt8(declaredLength & 0xff))
        d.append(payload)
        return d
    }

    func testRoundTripEveryFrame() throws {
        for frame in allFrames() {
            let bytes = try LinkCodec.encode(frame)
            var decoder = FrameDecoder()
            decoder.push(bytes)
            let decoded = try decoder.next()
            XCTAssertEqual(decoded, frame, "round-trip mismatch for \(frame)")
            XCTAssertNil(try decoder.next(), "decoder should be drained after one frame")
            try decoder.close()
        }
    }

    func testPartialBufferReassembles() throws {
        let frame = Frame.chunk(ChunkFrame(messageID: id, uti: LinkUTI.png, seq: 0, bytes: Data(repeating: 7, count: 5000)))
        let bytes = try LinkCodec.encode(frame)
        var decoder = FrameDecoder()
        let split = bytes.count / 3
        decoder.push(bytes.prefix(split))
        XCTAssertNil(try decoder.next(), "should need more bytes")
        decoder.push(bytes.suffix(from: bytes.startIndex + split))
        XCTAssertEqual(try decoder.next(), frame)
        XCTAssertNil(try decoder.next())
    }

    func testTrailingBytesPreservedAcrossFrames() throws {
        let a = Frame.ack(id)
        let b = Frame.itemEnd(id)
        var stream = Data()
        stream.append(try LinkCodec.encode(a))
        stream.append(try LinkCodec.encode(b))
        var decoder = FrameDecoder()
        decoder.push(stream)
        XCTAssertEqual(try decoder.next(), a)
        XCTAssertEqual(try decoder.next(), b)
        XCTAssertNil(try decoder.next())
    }

    func testBadMagicRejected() {
        let bytes = rawEnvelope(type: FrameType.ack.rawValue, declaredLength: 0, magic: [0x00, 0x00, 0x00, 0x00])
        var decoder = FrameDecoder()
        decoder.push(bytes)
        XCTAssertThrowsError(try decoder.next()) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .badMagic)
        }
    }

    func testUnknownFrameTypeRejected() {
        let bytes = rawEnvelope(type: 99, declaredLength: 0)
        var decoder = FrameDecoder()
        decoder.push(bytes)
        XCTAssertThrowsError(try decoder.next()) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .unknownFrameType)
        }
    }

    func testOversizeLengthRejected() {
        let bytes = rawEnvelope(type: FrameType.ack.rawValue, declaredLength: 100)
        var decoder = FrameDecoder(maxFrameLength: 16)
        decoder.push(bytes)
        XCTAssertThrowsError(try decoder.next()) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .oversizeLength)
        }
    }

    func testTruncatedFrameRejectedAtClose() throws {
        let frame = Frame.chunk(ChunkFrame(messageID: id, uti: LinkUTI.plainText, seq: 0, bytes: Data("abcdef".utf8)))
        let bytes = try LinkCodec.encode(frame)
        var decoder = FrameDecoder()
        decoder.push(bytes.dropLast(2)) // stream ends mid-frame
        XCTAssertNil(try decoder.next(), "incomplete frame should not be emitted")
        XCTAssertThrowsError(try decoder.close()) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .truncatedFrame)
        }
    }

    func testChunkBytesSurviveExactly() throws {
        let payload = Data((0..<1024).map { UInt8($0 & 0xff) })
        let frame = Frame.chunk(ChunkFrame(messageID: id, uti: LinkUTI.fileURL, seq: 42, bytes: payload))
        let bytes = try LinkCodec.encode(frame)
        var decoder = FrameDecoder()
        decoder.push(bytes)
        guard case let .chunk(decoded)? = try decoder.next() else { return XCTFail("expected chunk") }
        XCTAssertEqual(decoded.bytes, payload)
        XCTAssertEqual(decoded.seq, 42)
        XCTAssertEqual(decoded.uti, LinkUTI.fileURL)
        XCTAssertEqual(decoded.messageID, id)
    }
}
