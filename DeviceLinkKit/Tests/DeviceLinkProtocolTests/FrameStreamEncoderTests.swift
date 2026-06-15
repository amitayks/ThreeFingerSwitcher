import XCTest
@testable import DeviceLinkProtocol

/// The send-side encoder + the closed encode→decode round-trip against InboundAssembler.
final class FrameStreamEncoderTests: XCTestCase {

    private let id = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!

    /// Drive every encoded frame through an assembler and return the reassembled item.
    private func reassemble(_ frames: [Frame]) throws -> LinkItem? {
        var assembler = InboundAssembler()
        var out: LinkItem?
        for f in frames {
            if case let .item(item) = try assembler.consume(f) { out = item }
        }
        return out
    }

    func testSmallSingleRepEncoding() {
        let item = LinkItem(messageID: id, kind: .text, representations: [LinkUTI.plainText: Data("hi".utf8)])
        let frames = FrameStreamEncoder().frames(for: item)
        XCTAssertEqual(frames.count, 3)
        guard case let .itemBegin(header) = frames[0] else { return XCTFail("expected itemBegin") }
        XCTAssertEqual(header.manifest[LinkUTI.plainText], 2)
        guard case let .chunk(c) = frames[1] else { return XCTFail("expected chunk") }
        XCTAssertEqual(c.seq, 0)
        XCTAssertEqual(c.bytes, Data("hi".utf8))
        guard case .itemEnd = frames[2] else { return XCTFail("expected itemEnd") }
    }

    func testLargeRepIsBoundedAndConsecutive() {
        let big = Data((0..<1000).map { UInt8($0 & 0xff) })
        let item = LinkItem(messageID: id, kind: .file, representations: [LinkUTI.fileURL: big], suggestedName: "x.bin")
        let bound = 256
        let frames = FrameStreamEncoder(chunkByteBound: bound).frames(for: item)
        let chunks: [ChunkFrame] = frames.compactMap { if case let .chunk(c) = $0 { return c }; return nil }
        XCTAssertEqual(chunks.count, (1000 + bound - 1) / bound) // ceil
        XCTAssertEqual(chunks.map(\.seq), Array(0..<UInt32(chunks.count)))
        XCTAssertTrue(chunks.allSatisfy { $0.bytes.count <= bound })
        XCTAssertEqual(chunks.reduce(Data()) { $0 + $1.bytes }, big)
    }

    func testDeterministicOutput() {
        let item = LinkItem(messageID: id, kind: .richText,
                            representations: [LinkUTI.rtf: Data("rtf".utf8), LinkUTI.plainText: Data("plain".utf8)])
        let a = FrameStreamEncoder().frames(for: item)
        let b = FrameStreamEncoder().frames(for: item)
        XCTAssertEqual(a, b)
    }

    func testRoundTripMultiRepMixedSizes() throws {
        let item = LinkItem(
            messageID: id, kind: .image,
            representations: [
                LinkUTI.png: Data((0..<700).map { UInt8($0 & 0xff) }),  // > bound → multi-chunk
                LinkUTI.plainText: Data("caption".utf8),                 // small
            ],
            suggestedName: "pic.png",
            capturedAt: nil,
            origin: DeviceIdentity(id: "dev", name: "iPhone"))
        let frames = FrameStreamEncoder(chunkByteBound: 128).frames(for: item)
        let back = try reassemble(frames)
        XCTAssertEqual(back, item)
    }

    func testRoundTripEmptyRepresentation() throws {
        let item = LinkItem(messageID: id, kind: .text,
                            representations: [LinkUTI.plainText: Data(), LinkUTI.url: Data("u".utf8)])
        let frames = FrameStreamEncoder().frames(for: item)
        let back = try reassemble(frames)
        XCTAssertEqual(back, item, "empty representation must survive the round-trip")
        XCTAssertEqual(back?.representations[LinkUTI.plainText], Data())
    }
}
