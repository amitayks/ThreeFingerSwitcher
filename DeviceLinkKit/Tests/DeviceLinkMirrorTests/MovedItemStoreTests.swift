import XCTest
import DeviceLinkProtocol
@testable import DeviceLinkMirror

final class MovedItemStoreTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tfs-mirror-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func blobCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("blobs"), includingPropertiesForKeys: nil))?.count ?? 0
    }

    private func textItem(_ s: String, at t: TimeInterval, direction: MoveDirection = .received) -> MovedItem {
        let link = LinkItem(messageID: UUID(), kind: .text, representations: [LinkUTI.plainText: Data(s.utf8)],
                            origin: DeviceIdentity(id: "mac", name: "Mac"))
        return MovedItem.from(link, direction: direction, at: Date(timeIntervalSince1970: t))
    }

    // MARK: Mapping

    func testMappingTextTitleAndReps() {
        let item = textItem("hello\nworld", at: 1)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.title, "hello")
        XCTAssertEqual(item.peerName, "Mac")
        XCTAssertEqual(item.representations[LinkUTI.plainText], Data("hello\nworld".utf8))
    }

    func testMappingFileTitle() {
        let link = LinkItem(messageID: UUID(), kind: .file, representations: ["public.data": Data([1, 2, 3])],
                            suggestedName: "report.pdf")
        let item = MovedItem.from(link, direction: .sent, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(item.title, "report.pdf")
        XCTAssertEqual(item.direction, .sent)
    }

    // MARK: Store

    func testInsertListNewestFirst() {
        let store = MovedItemStore(directory: dir)
        store.insert(textItem("old", at: 100))
        store.insert(textItem("new", at: 200))
        XCTAssertEqual(store.list().map(\.title), ["new", "old"])
    }

    func testBytesSurviveReload() {
        let bytes = Data((0..<5000).map { UInt8($0 & 0xff) })
        let link = LinkItem(messageID: UUID(), kind: .image, representations: [LinkUTI.png: bytes])
        let store = MovedItemStore(directory: dir)
        store.insert(MovedItem.from(link, direction: .received, at: Date(timeIntervalSince1970: 1)))

        let reloaded = MovedItemStore(directory: dir)
        XCTAssertEqual(reloaded.list().first?.representations[LinkUTI.png], bytes)
    }

    func testReplaceBySameID() {
        let store = MovedItemStore(directory: dir)
        var item = textItem("first", at: 1)
        store.insert(item)
        item.title = "second"
        store.insert(item) // same id
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.list().first?.title, "second")
    }

    func testRemoveAndClearDeleteBlobs() {
        let store = MovedItemStore(directory: dir)
        let a = textItem("a", at: 1)
        store.insert(a)
        store.insert(textItem("b", at: 2))
        XCTAssertEqual(blobCount(), 2)
        store.remove(id: a.id)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(blobCount(), 1)
        store.clear()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(blobCount(), 0)
    }

    func testCountCapEvictsOldestAndDeletesBlobs() {
        let store = MovedItemStore(directory: dir, maxCount: 2)
        store.insert(textItem("a", at: 100))
        store.insert(textItem("b", at: 200))
        store.insert(textItem("c", at: 300)) // evicts "a"
        XCTAssertEqual(store.list().map(\.title), ["c", "b"])
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(blobCount(), 2, "evicted item's blob is deleted")
    }
}
