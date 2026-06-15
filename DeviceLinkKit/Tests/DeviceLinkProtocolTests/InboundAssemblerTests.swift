import XCTest
@testable import DeviceLinkProtocol

/// Reassembly contract: emit complete items, interleave by message id, and reject every protocol
/// violation (mismatch, unknown message, duplicate, bad sequence), discarding state on failure/cancel.
final class InboundAssemblerTests: XCTestCase {

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    /// One-chunk text item frames.
    private func textFrames(_ id: UUID, _ text: String) -> [Frame] {
        let data = Data(text.utf8)
        let header = ItemHeader(messageID: id, kind: .text, manifest: [LinkUTI.plainText: UInt32(data.count)])
        return [
            .itemBegin(header),
            .chunk(ChunkFrame(messageID: id, uti: LinkUTI.plainText, seq: 0, bytes: data)),
            .itemEnd(id),
        ]
    }

    func testCompleteItemEmitted() throws {
        var assembler = InboundAssembler()
        var emitted: LinkItem?
        for frame in textFrames(a, "hello world") {
            if case let .item(item) = try assembler.consume(frame) { emitted = item }
        }
        XCTAssertEqual(emitted?.messageID, a)
        XCTAssertEqual(emitted?.kind, .text)
        XCTAssertEqual(emitted?.representations[LinkUTI.plainText], Data("hello world".utf8))
        XCTAssertEqual(assembler.inFlightCount, 0)
    }

    func testInterleavedSmallAheadOfLarge() throws {
        // B is a 2-chunk "file"; A is a small text item that arrives and completes mid-B.
        let big = Data((0..<5000).map { UInt8($0 & 0xff) })
        let half = big.count / 2
        let bHeader = ItemHeader(messageID: b, kind: .file, manifest: [LinkUTI.fileURL: UInt32(big.count)])
        let aData = Data("ping".utf8)
        let aHeader = ItemHeader(messageID: a, kind: .text, manifest: [LinkUTI.plainText: UInt32(aData.count)])

        let sequence: [Frame] = [
            .itemBegin(bHeader),
            .itemBegin(aHeader),
            .chunk(ChunkFrame(messageID: a, uti: LinkUTI.plainText, seq: 0, bytes: aData)),
            .chunk(ChunkFrame(messageID: b, uti: LinkUTI.fileURL, seq: 0, bytes: big.prefix(half))),
            .itemEnd(a), // A completes while B is still mid-flight
            .chunk(ChunkFrame(messageID: b, uti: LinkUTI.fileURL, seq: 1, bytes: big.suffix(from: big.startIndex + half))),
            .itemEnd(b),
        ]

        var assembler = InboundAssembler()
        var emitted: [LinkItem] = []
        for frame in sequence {
            if case let .item(item) = try assembler.consume(frame) { emitted.append(item) }
        }
        XCTAssertEqual(emitted.map(\.messageID), [a, b], "A should emit before B")
        XCTAssertEqual(emitted.first?.representations[LinkUTI.plainText], aData)
        XCTAssertEqual(emitted.last?.representations[LinkUTI.fileURL], big)
        XCTAssertEqual(assembler.inFlightCount, 0)
    }

    func testByteCountMismatchRejectedAndStateDiscarded() {
        var assembler = InboundAssembler()
        // Manifest says 10 bytes; we send 3, then end.
        let header = ItemHeader(messageID: a, kind: .text, manifest: [LinkUTI.plainText: 10])
        XCTAssertNoThrow(try assembler.consume(.itemBegin(header)))
        XCTAssertNoThrow(try assembler.consume(.chunk(ChunkFrame(messageID: a, uti: LinkUTI.plainText, seq: 0, bytes: Data("abc".utf8)))))
        XCTAssertThrowsError(try assembler.consume(.itemEnd(a))) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .manifestMismatch)
        }
        XCTAssertEqual(assembler.inFlightCount, 0, "failed message must be discarded")
    }

    func testOverflowBeyondManifestRejected() {
        var assembler = InboundAssembler()
        let header = ItemHeader(messageID: a, kind: .text, manifest: [LinkUTI.plainText: 2])
        XCTAssertNoThrow(try assembler.consume(.itemBegin(header)))
        XCTAssertThrowsError(try assembler.consume(.chunk(ChunkFrame(messageID: a, uti: LinkUTI.plainText, seq: 0, bytes: Data("abcdef".utf8))))) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .manifestMismatch)
        }
        XCTAssertEqual(assembler.inFlightCount, 0)
    }

    func testCancelDiscardsPartialState() throws {
        var assembler = InboundAssembler()
        let header = ItemHeader(messageID: a, kind: .text, manifest: [LinkUTI.plainText: 10])
        _ = try assembler.consume(.itemBegin(header))
        _ = try assembler.consume(.chunk(ChunkFrame(messageID: a, uti: LinkUTI.plainText, seq: 0, bytes: Data("abc".utf8))))
        let out = try assembler.consume(.cancel(a))
        XCTAssertEqual(out, .none)
        XCTAssertEqual(assembler.inFlightCount, 0)
    }

    func testChunkForUnknownMessageRejected() {
        var assembler = InboundAssembler()
        XCTAssertThrowsError(try assembler.consume(.chunk(ChunkFrame(messageID: a, uti: LinkUTI.plainText, seq: 0, bytes: Data("x".utf8))))) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .unknownMessage)
        }
    }

    func testDuplicateItemBeginRejected() throws {
        var assembler = InboundAssembler()
        let header = ItemHeader(messageID: a, kind: .text, manifest: [LinkUTI.plainText: 1])
        _ = try assembler.consume(.itemBegin(header))
        XCTAssertThrowsError(try assembler.consume(.itemBegin(header))) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .duplicateMessage)
        }
    }

    func testBadSequenceRejected() throws {
        var assembler = InboundAssembler()
        let header = ItemHeader(messageID: a, kind: .image, manifest: [LinkUTI.png: 100])
        _ = try assembler.consume(.itemBegin(header))
        XCTAssertThrowsError(try assembler.consume(.chunk(ChunkFrame(messageID: a, uti: LinkUTI.png, seq: 1, bytes: Data(repeating: 0, count: 10))))) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .badSequence)
        }
    }

    func testControlFramesPassThrough() throws {
        var assembler = InboundAssembler()
        let hello = Frame.hello(DeviceIdentity(id: "x", name: "y"), ProtocolVersion(major: 1, minor: 0))
        XCTAssertEqual(try assembler.consume(hello), .control(hello))
    }
}
