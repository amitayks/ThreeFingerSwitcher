import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the clipboard store's pure logic (de-dup, retention eviction, recent-window ordering)
/// and its on-disk persistence (round-trip, blob externalization, schema version, pin survival).
@MainActor
final class ClipboardStoreTests: XCTestCase {

    // MARK: Helpers

    private func entry(_ text: String, at seconds: TimeInterval, pinned: Bool = false,
                       id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id,
                       capturedAt: Date(timeIntervalSince1970: seconds),
                       kind: .text,
                       key: ClipboardKey.fromText(text),
                       pinned: pinned,
                       representations: [ClipboardUTI.plainText: .inline(Data(text.utf8))],
                       fingerprint: "text:\(text)")
    }

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-clip-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: De-dup (pure)

    func testDedupBumpsRecencyInsteadOfDuplicating() {
        let base = [entry("hello", at: 100), entry("world", at: 200)]
        let dup = entry("hello", at: 300)   // same fingerprint as the first
        let result = ClipboardStore.dedup(inserting: dup, into: base)
        XCTAssertEqual(result.count, 2, "duplicate content must not create a second entry")
        let hello = result.first { $0.fingerprint == "text:hello" }
        XCTAssertEqual(hello?.capturedAt, Date(timeIntervalSince1970: 300), "recency is bumped to the new copy")
    }

    func testDedupPreservesPinOnExistingEntry() {
        let pinnedID = UUID()
        let base = [entry("keep", at: 100, pinned: true, id: pinnedID)]
        let dup = entry("keep", at: 400)
        let result = ClipboardStore.dedup(inserting: dup, into: base)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].pinned, "re-copying a pinned entry keeps it pinned")
        XCTAssertEqual(result[0].id, pinnedID, "the original identity is preserved")
    }

    func testDedupAppendsNewContent() {
        let base = [entry("a", at: 100)]
        let result = ClipboardStore.dedup(inserting: entry("b", at: 200), into: base)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: Retention (pure)

    func testCountCapEvictsOldestNonPinnedFirst() {
        let entries = (1...5).map { entry("e\($0)", at: TimeInterval($0 * 100)) }   // e5 newest
        let retention = ClipboardStore.Retention(maxCount: 3, maxBytes: 0, maxAge: 0)
        let kept = ClipboardStore.evict(entries, retention: retention, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(kept.count, 3)
        let keys = Set(kept.map(\.key))
        XCTAssertTrue(keys.isSuperset(of: ["e5", "e4", "e3"]), "newest three are kept")
        XCTAssertFalse(keys.contains("e1"), "oldest evicted")
    }

    func testPinnedAreExemptFromCountEviction() {
        var entries = (1...5).map { entry("e\($0)", at: TimeInterval($0 * 100)) }
        entries[0].pinned = true   // e1 is the oldest but pinned
        let retention = ClipboardStore.Retention(maxCount: 2, maxBytes: 0, maxAge: 0)
        let kept = ClipboardStore.evict(entries, retention: retention, now: Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(kept.contains { $0.key == "e1" }, "pinned oldest entry survives eviction")
    }

    func testAgeCapDropsOldNonPinned() {
        let entries = [entry("old", at: 0), entry("new", at: 1000)]
        let retention = ClipboardStore.Retention(maxCount: 100, maxBytes: 0, maxAge: 500)
        let kept = ClipboardStore.evict(entries, retention: retention, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(kept.map(\.key), ["new"], "entry older than maxAge is dropped")
    }

    // MARK: recentWindow (pure)

    func testRecentWindowOrdersPinnedFirst() {
        var entries = [entry("a", at: 100), entry("b", at: 200), entry("c", at: 300)]
        entries[0].pinned = true   // "a" is oldest but pinned
        let window = ClipboardStore.recentWindow(entries, limit: 10)
        XCTAssertEqual(window.first?.key, "a", "pinned entry floats to the top")
        XCTAssertEqual(window.map(\.key), ["a", "c", "b"], "then non-pinned newest-first")
    }

    func testRecentWindowRespectsLimit() {
        let entries = (1...10).map { entry("e\($0)", at: TimeInterval($0)) }
        let window = ClipboardStore.recentWindow(entries, limit: 3)
        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.map(\.key), ["e10", "e9", "e8"])
    }

    // MARK: Persistence (disk)

    func testInsertAndReloadRoundTrips() {
        let dir = tempDir()
        let store = ClipboardStore(directory: dir)
        store.insert(entry("alpha", at: 100))
        store.insert(entry("beta", at: 200))

        let reloaded = ClipboardStore(directory: dir)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.recentWindow(limit: 10).map(\.key), ["beta", "alpha"])
    }

    func testPinSurvivesReload() {
        let dir = tempDir()
        let id = UUID()
        let store = ClipboardStore(directory: dir)
        store.insert(entry("pinme", at: 100, id: id))
        XCTAssertEqual(store.togglePin(id: id), true)

        let reloaded = ClipboardStore(directory: dir)
        XCTAssertTrue(reloaded.recentWindow(limit: 10).first?.pinned ?? false)
    }

    func testLargePayloadExternalizesToBlobAndMaterializes() {
        let dir = tempDir()
        let store = ClipboardStore(directory: dir)
        let big = Data(repeating: 0xAB, count: 64 * 1024)   // > blob threshold
        let img = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 100), kind: .image,
                                 key: "Image 100×100",
                                 representations: [ClipboardUTI.png: .inline(big)],
                                 fingerprint: "img:1")
        store.insert(img)

        // A blob file should exist on disk (payload not stored inline in the index).
        let blobs = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("blobs").path)) ?? []
        XCTAssertFalse(blobs.isEmpty, "large payload is externalized to a blob file")

        // Reload and confirm the bytes materialize back.
        let reloaded = ClipboardStore(directory: dir)
        let got = reloaded.recentWindow(limit: 1).first
        XCTAssertEqual(got?.data(for: ClipboardUTI.png), big, "blob materializes to the original bytes")
    }

    func testClearKeepsPinnedByDefault() {
        let dir = tempDir()
        let pid = UUID()
        let store = ClipboardStore(directory: dir)
        store.insert(entry("keep", at: 100, pinned: true, id: pid))
        store.insert(entry("drop", at: 200))
        store.clear()
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.recentWindow(limit: 10).first?.key, "keep")
    }

    func testClearIncludingPinnedWipesAll() {
        let dir = tempDir()
        let store = ClipboardStore(directory: dir)
        store.insert(entry("keep", at: 100, pinned: true))
        store.clear(includingPinned: true)
        XCTAssertTrue(store.isEmpty)
    }
}
