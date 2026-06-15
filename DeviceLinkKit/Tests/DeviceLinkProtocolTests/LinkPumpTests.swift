import XCTest
@testable import DeviceLinkProtocol

/// The pump's loopback fidelity under arbitrary buffer fragmentation — the end-to-end proof of the
/// encode→codec→decode→assemble stack.
final class LinkPumpTests: XCTestCase {

    private let id = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!

    private func sampleItem() -> LinkItem {
        LinkItem(messageID: id, kind: .image,
                 representations: [
                    LinkUTI.png: Data((0..<900).map { UInt8($0 & 0xff) }),  // multi-chunk at small bound
                    LinkUTI.plainText: Data("caption".utf8),
                 ],
                 suggestedName: "p.png",
                 origin: DeviceIdentity(id: "d", name: "iPhone"))
    }

    func testOutboundIsFramePerBufferAndIngestsToItem() throws {
        var sender = LinkPump(chunkByteBound: 64)
        var receiver = LinkPump()
        let item = sampleItem()
        let buffers = try sender.outbound(item)
        XCTAssertGreaterThan(buffers.count, 3, "expected itemBegin + several chunks + itemEnd")

        var got: [LinkPump.Inbound] = []
        for b in buffers { got += try receiver.ingest(b) }
        XCTAssertEqual(got, [.item(item)])
    }

    func testLoopbackConcatenated() throws {
        var sender = LinkPump(chunkByteBound: 64)
        var receiver = LinkPump()
        let item = sampleItem()
        let all = try sender.outbound(item).reduce(Data(), +)
        let got = try receiver.ingest(all)
        XCTAssertEqual(got, [.item(item)])
    }

    func testLoopbackReSplitAtArbitraryBoundaries() throws {
        var sender = LinkPump(chunkByteBound: 64)
        var receiver = LinkPump()
        let item = sampleItem()
        let all = try sender.outbound(item).reduce(Data(), +)

        // Re-slice into 37-byte pieces that don't align with frame boundaries.
        var got: [LinkPump.Inbound] = []
        var offset = all.startIndex
        while offset < all.endIndex {
            let end = min(offset + 37, all.endIndex)
            got += try receiver.ingest(all[offset..<end])
            offset = end
        }
        XCTAssertEqual(got, [.item(item)])
    }

    func testMalformedBytesThrow() {
        var receiver = LinkPump()
        XCTAssertThrowsError(try receiver.ingest(Data([0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6]))) {
            XCTAssertTrue($0 is LinkProtocolError)
        }
    }

    func testTruncatedStreamFailsOnFinish() throws {
        var sender = LinkPump(chunkByteBound: 64)
        var receiver = LinkPump()
        let all = try sender.outbound(sampleItem()).reduce(Data(), +)
        _ = try receiver.ingest(all.dropLast(5)) // stream cut short
        XCTAssertThrowsError(try receiver.finish()) {
            XCTAssertEqual(($0 as? LinkProtocolError)?.code, .truncatedFrame)
        }
    }

    func testControlFrameRoundTrips() throws {
        var sender = LinkPump()
        var receiver = LinkPump()
        let hello = Frame.hello(DeviceIdentity(id: "x", name: "Mac"), LinkProtocol.version)
        let got = try receiver.ingest(try sender.outbound(control: hello))
        XCTAssertEqual(got, [.control(hello)])
    }
}
