import XCTest
import DeviceLinkProtocol
@testable import ThreeFingerSwitcherCore

/// The send-side adapter (ClipboardEntry → LinkItem) and its round-trip fidelity with the inbound adapter.
final class LinkOutboundAdapterTests: XCTestCase {

    private var tempDir: URL!
    private let outbound = LinkOutboundAdapter()
    private let mac = DeviceIdentity(id: "mac", name: "Mac")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tfs-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func textEntry(_ s: String) -> ClipboardEntry {
        ClipboardEntry(capturedAt: Date(), kind: .text, key: s,
                       representations: [ClipboardUTI.plainText: .inline(Data(s.utf8))], fingerprint: "text:\(s)")
    }

    func testTextMapping() throws {
        let item = try outbound.linkItem(from: textEntry("hi"), origin: mac)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.representations[ClipboardUTI.plainText], Data("hi".utf8))
        XCTAssertEqual(item.origin, mac)
    }

    func testUrlMapping() throws {
        let entry = ClipboardEntry(capturedAt: Date(), kind: .url, key: "u",
                                   representations: [ClipboardUTI.url: .inline(Data("https://x".utf8))],
                                   fingerprint: "url:https://x")
        let item = try outbound.linkItem(from: entry, origin: mac)
        XCTAssertEqual(item.kind, .url)
        XCTAssertEqual(item.representations[ClipboardUTI.url], Data("https://x".utf8))
    }

    func testEmptyEntryThrows() {
        let empty = ClipboardEntry(capturedAt: Date(), kind: .text, key: "", representations: [:], fingerprint: "text:")
        XCTAssertThrowsError(try outbound.linkItem(from: empty, origin: mac)) {
            XCTAssertEqual($0 as? LinkOutboundError, .noContent)
        }
    }

    func testFileEntrySendsBytes() throws {
        let src = tempDir.appendingPathComponent("doc.pdf")
        let bytes = Data((0..<1500).map { UInt8($0 & 0xff) })
        try bytes.write(to: src)
        let entry = ClipboardEntry(capturedAt: Date(), kind: .file, key: "doc.pdf",
                                   representations: [ClipboardUTI.fileURL: .inline(Data(src.absoluteString.utf8))],
                                   fingerprint: "file:\(src.path)")
        let item = try outbound.linkItem(from: entry, origin: mac)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.suggestedName, "doc.pdf")
        XCTAssertEqual(item.representations[LinkOutboundAdapter.fileContentUTI], bytes)
    }

    func testUnreadableFileThrows() {
        let entry = ClipboardEntry(capturedAt: Date(), kind: .file, key: "ghost",
                                   representations: [ClipboardUTI.fileURL: .inline(Data("file:///nope/ghost.bin".utf8))],
                                   fingerprint: "file:/nope/ghost.bin")
        XCTAssertThrowsError(try outbound.linkItem(from: entry, origin: mac)) {
            XCTAssertEqual($0 as? LinkOutboundError, .unreadableFile)
        }
    }

    // MARK: Round-trip with the inbound adapter

    func testTextRoundTrip() throws {
        let item = try outbound.linkItem(from: textEntry("round trip"), origin: mac)
        let inbound = LinkInboundAdapter(inboxDirectory: tempDir.appendingPathComponent("inbox"))
        let back = try inbound.entry(from: item)
        XCTAssertEqual(back.kind, .text)
        XCTAssertEqual(back.data(for: ClipboardUTI.plainText), Data("round trip".utf8))
        XCTAssertEqual(back.peerDeviceName, "Mac")
    }

    func testFileRoundTrip() throws {
        let src = tempDir.appendingPathComponent("photo.png")
        let bytes = Data((0..<3000).map { UInt8(($0 * 7) & 0xff) })
        try bytes.write(to: src)
        let entry = ClipboardEntry(capturedAt: Date(), kind: .file, key: "photo.png",
                                   representations: [ClipboardUTI.fileURL: .inline(Data(src.absoluteString.utf8))],
                                   fingerprint: "file:\(src.path)")

        let item = try outbound.linkItem(from: entry, origin: mac)
        let inbound = LinkInboundAdapter(inboxDirectory: tempDir.appendingPathComponent("inbox"))
        let back = try inbound.entry(from: item)

        let urlData = try XCTUnwrap(back.data(for: ClipboardUTI.fileURL))
        let inboxURL = try XCTUnwrap(URL(string: String(decoding: urlData, as: UTF8.self)))
        XCTAssertEqual(try Data(contentsOf: inboxURL), bytes, "file content survives the full Mac→wire→Mac round-trip")
        XCTAssertTrue(inboxURL.lastPathComponent.hasSuffix("photo.png"))
    }
}
