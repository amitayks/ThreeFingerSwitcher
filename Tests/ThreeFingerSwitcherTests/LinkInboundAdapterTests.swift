import XCTest
import DeviceLinkProtocol
@testable import ThreeFingerSwitcherCore

/// The receive-side adapter: LinkItem → ClipboardEntry mapping, inbox file persistence, peer provenance,
/// and de-dup against an identical local entry through the existing store.
final class LinkInboundAdapterTests: XCTestCase {

    private var tempDir: URL!
    private var adapter: LinkInboundAdapter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tfs-inbox-\(UUID().uuidString)")
        adapter = LinkInboundAdapter(inboxDirectory: tempDir.appendingPathComponent("inbox"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func linkItem(_ kind: LinkItemKind,
                          reps: [String: Data],
                          name: String? = nil,
                          device: String? = "iPhone") -> LinkItem {
        LinkItem(messageID: UUID(), kind: kind, representations: reps,
                 suggestedName: name, capturedAt: nil,
                 origin: device.map { DeviceIdentity(id: "dev", name: $0) })
    }

    // MARK: Mapping

    func testTextItemMapping() throws {
        let entry = try adapter.entry(from: linkItem(.text, reps: [LinkUTI.plainText: Data("hello".utf8)]))
        XCTAssertEqual(entry.kind, .text)
        XCTAssertEqual(entry.data(for: ClipboardUTI.plainText), Data("hello".utf8))
        XCTAssertEqual(entry.key, "hello")
        XCTAssertEqual(entry.fingerprint, "text:hello", "must match the local capture fingerprint convention")
        XCTAssertEqual(entry.origin, .peer(deviceName: "iPhone"))
    }

    func testUrlItemMapping() throws {
        let entry = try adapter.entry(from: linkItem(.url, reps: [LinkUTI.url: Data("https://example.com".utf8)]))
        XCTAssertEqual(entry.kind, .url)
        XCTAssertEqual(entry.fingerprint, "url:https://example.com")
        XCTAssertEqual(entry.data(for: ClipboardUTI.url), Data("https://example.com".utf8))
        XCTAssertEqual(entry.data(for: ClipboardUTI.plainText), Data("https://example.com".utf8))
    }

    func testColorItemMapping() throws {
        let colorBytes = Data([1, 2, 3, 4])
        let entry = try adapter.entry(from: linkItem(.color, reps: [LinkUTI.color: colorBytes]))
        XCTAssertEqual(entry.kind, .color)
        XCTAssertEqual(entry.key, "Color")
        XCTAssertTrue(entry.fingerprint.hasPrefix("color:"))
        XCTAssertEqual(entry.data(for: ClipboardUTI.color), colorBytes)
    }

    func testRichTextItemMapping() throws {
        let rtf = Data("{\\rtf1 hi}".utf8)
        let entry = try adapter.entry(from: linkItem(.richText, reps: [LinkUTI.rtf: rtf, LinkUTI.plainText: Data("hi".utf8)]))
        XCTAssertEqual(entry.kind, .richText)
        XCTAssertEqual(entry.key, "hi")
        XCTAssertTrue(entry.fingerprint.hasPrefix("rich:"))
        XCTAssertEqual(entry.data(for: ClipboardUTI.rtf), rtf)
    }

    func testImageItemMappingDimensionsKey() throws {
        // Build a deterministic 4x2 PNG without a display (no lockFocus).
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let entry = try adapter.entry(from: linkItem(.image, reps: [LinkUTI.png: png]))
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.key, "Image 4×2")
        XCTAssertTrue(entry.fingerprint.hasPrefix("image:"))
        XCTAssertEqual(entry.data(for: ClipboardUTI.png), png)
    }

    func testMissingRepresentationThrows() {
        XCTAssertThrowsError(try adapter.entry(from: linkItem(.text, reps: [:]))) {
            XCTAssertEqual($0 as? LinkInboundError, .missingRepresentation(.text))
        }
    }

    // MARK: Files / inbox

    func testFileItemWritesToInboxAndReferencesIt() throws {
        let bytes = Data((0..<2048).map { UInt8($0 & 0xff) })
        let entry = try adapter.entry(from: linkItem(.file, reps: ["public.data": bytes], name: "report.pdf"))
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.key, "report.pdf")
        XCTAssertTrue(entry.fingerprint.hasPrefix("file:"))

        let urlData = try XCTUnwrap(entry.data(for: ClipboardUTI.fileURL))
        let url = try XCTUnwrap(URL(string: String(decoding: urlData, as: UTF8.self)))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the referenced file holds the received bytes")
        XCTAssertTrue(url.lastPathComponent.hasSuffix("report.pdf"))
    }

    func testInboxCreatedOnDemand() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: adapter.inboxDirectory.path))
        _ = try adapter.entry(from: linkItem(.file, reps: ["public.data": Data("x".utf8)], name: "a.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: adapter.inboxDirectory.path))
    }

    // MARK: Provenance

    func testProvenanceStamping() throws {
        let named = try adapter.entry(from: linkItem(.text, reps: [LinkUTI.plainText: Data("a".utf8)], device: "iPhone"))
        XCTAssertEqual(named.origin, .peer(deviceName: "iPhone"))
        XCTAssertTrue(named.isPeer)
        XCTAssertEqual(named.peerDeviceName, "iPhone")

        let anon = try adapter.entry(from: linkItem(.text, reps: [LinkUTI.plainText: Data("b".utf8)], device: nil))
        XCTAssertEqual(anon.origin, .peer(deviceName: nil))
        XCTAssertTrue(anon.isPeer)

        let local = ClipboardEntry(capturedAt: Date(), kind: .text, key: "c",
                                   representations: [:], fingerprint: "text:c")
        XCTAssertFalse(local.isPeer)
        XCTAssertNil(local.peerDeviceName)
    }

    // MARK: De-dup through the real store

    @MainActor
    func testPeerItemDedupsAgainstIdenticalLocal() throws {
        let storeDir = tempDir.appendingPathComponent("store")
        let store = ClipboardStore(directory: storeDir)
        // A pre-existing local copy of "shared".
        store.insert(ClipboardEntry(capturedAt: Date(), kind: .text, key: "shared",
                                    representations: [ClipboardUTI.plainText: .inline(Data("shared".utf8))],
                                    fingerprint: "text:shared"))
        XCTAssertEqual(store.allEntries().count, 1)

        // The same content arrives from the phone.
        let peer = try adapter.entry(from: linkItem(.text, reps: [LinkUTI.plainText: Data("shared".utf8)]))
        store.insert(peer)

        XCTAssertEqual(store.allEntries().count, 1, "identical content must de-dup, not duplicate")
    }
}
