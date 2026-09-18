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
        store.flush()   // persistence is async now — flush for a deterministic reload

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
        store.flush()

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
        store.flush()   // blob write is off-main now — flush before inspecting disk

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

    // MARK: Bounded band window + on-demand materialization (large-item perf)

    func testBandWindowTruncatesLargeTextAndFlags() {
        let store = ClipboardStore(directory: tempDir())
        let big = String(repeating: "A", count: ClipboardStore.previewByteCap * 4)
        store.insert(entry(big, at: 100))
        let banded = store.bandWindow(limit: 10).first
        XCTAssertEqual(banded?.isPreviewTruncated, true)
        let bytes = banded?.data(for: ClipboardUTI.plainText)?.count ?? 0
        XCTAssertLessThanOrEqual(bytes, ClipboardStore.previewByteCap, "band text is capped to previewByteCap")
        XCTAssertGreaterThan(bytes, 0)
    }

    func testBandWindowKeepsSmallTextWhole() {
        let store = ClipboardStore(directory: tempDir())
        store.insert(entry("short line", at: 100))
        let banded = store.bandWindow(limit: 10).first
        XCTAssertEqual(banded?.isPreviewTruncated, false)
        XCTAssertEqual(banded?.data(for: ClipboardUTI.plainText).flatMap { String(data: $0, encoding: .utf8) },
                       "short line")
    }

    func testBandWindowDropsImageBytes() {
        let store = ClipboardStore(directory: tempDir())
        let img = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 100), kind: .image, key: "Image",
                                 representations: [ClipboardUTI.png: .inline(Data(repeating: 0xAB, count: 200_000))],
                                 fingerprint: "img:1")
        store.insert(img)
        XCTAssertTrue(store.bandWindow(limit: 10).first?.representations.isEmpty ?? false,
                      "the band image entry carries no bytes (loaded on demand)")
    }

    func testMaterializedEntryReturnsFullContentNotPreview() {
        let store = ClipboardStore(directory: tempDir())
        let big = String(repeating: "Z", count: ClipboardStore.previewByteCap * 3)
        let id = UUID()
        store.insert(entry(big, at: 100, id: id))
        // Band is truncated; the on-demand full fetch restores the whole payload (for faithful paste).
        XCTAssertLessThanOrEqual(store.bandWindow(limit: 10).first?.data(for: ClipboardUTI.plainText)?.count ?? .max,
                                 ClipboardStore.previewByteCap)
        let full = store.materializedEntry(id: id)?.data(for: ClipboardUTI.plainText)
            .flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(full, big)
        XCTAssertNil(store.materializedEntry(id: UUID()), "unknown id → nil")
    }

    func testLargeTextExternalizedKeepsIndexSmall() throws {
        let dir = tempDir()
        let store = ClipboardStore(directory: dir)
        let big = String(repeating: "Q", count: 1_000_000)   // ~1 MB
        // Bounded fingerprint, mirroring the monitor (which hashes) — fingerprints live inline in the
        // index, so an unbounded raw-text fingerprint would itself defeat the "index stays small" goal.
        let e = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 100), kind: .text,
                               key: ClipboardKey.fromText(big),
                               representations: [ClipboardUTI.plainText: .inline(Data(big.utf8))],
                               fingerprint: "text:deadbeef")
        store.insert(e)
        store.flush()
        let indexBytes = try Data(contentsOf: dir.appendingPathComponent("index.json")).count
        XCTAssertLessThan(indexBytes, 50_000, "index must not embed the 1 MB payload (blob-externalized)")
    }

    func testTransientTruncationFlagIsNotPersisted() throws {
        let dir = tempDir()
        let store = ClipboardStore(directory: dir)
        store.insert(entry("x", at: 100))
        store.flush()
        let json = String(data: try Data(contentsOf: dir.appendingPathComponent("index.json")), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("isPreviewTruncated"), "transient band flag must stay out of the schema")
    }

    // MARK: - Byte cap counts blob-backed entries (payloadByteSize)

    /// The byte cap used to count only INLINE bytes, so a blob-backed entry (every entry after a relaunch)
    /// cost 0 and disk was bounded only by `maxCount`. It now counts the persisted `payloadByteSize`.
    func testByteCapCountsBlobBackedEntries() {
        let blobBacked = (1...3).map { i -> ClipboardEntry in
            ClipboardEntry(capturedAt: Date(timeIntervalSince1970: TimeInterval(i * 100)), kind: .image,
                           key: "Image \(i)", representations: [ClipboardUTI.png: .blob("img\(i).bin")],
                           fingerprint: "img:\(i)", payloadByteSize: 100_000)
        }
        XCTAssertEqual(blobBacked[0].inlineByteSize, 0, "precondition: an unresolved blob has no inline bytes")
        let retention = ClipboardStore.Retention(maxCount: 100, maxBytes: 250_000, maxAge: 0)
        let kept = ClipboardStore.evict(blobBacked, retention: retention, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(kept.map(\.key), ["Image 3", "Image 2"], "two fit the budget, newest first; the oldest is evicted")
    }

    func testPayloadByteSizeDefaultsToInlineBytesAndSurvivesDedup() {
        let e = entry("hello", at: 100)
        XCTAssertEqual(e.payloadByteSize, 5)
        var existing = entry("hello", at: 50)
        existing.payloadByteSize = 999   // stale
        let merged = ClipboardStore.dedup(inserting: e, into: [existing])
        XCTAssertEqual(merged[0].payloadByteSize, 5, "a re-copy refreshes the size with its representations")
    }

    /// The size is persisted with the entry, and an index written before the key existed (stripped here)
    /// is back-filled on load from the blob files' sizes — so the cap is honest after an upgrade too.
    func testPayloadByteSizePersistsAndBackfillsLegacyIndexFromBlobSizes() throws {
        let dir = tempDir()
        let store = ClipboardStore(directory: dir)
        let big = Data(repeating: 0xAB, count: 64 * 1024)   // > blob threshold → externalized
        store.insert(ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 100), kind: .image, key: "Image",
                                    representations: [ClipboardUTI.png: .inline(big)], fingerprint: "img:1"))
        store.flush()

        XCTAssertEqual(ClipboardStore(directory: dir).allEntries().first?.payloadByteSize, big.count,
                       "the size round-trips through the index")

        // Simulate a legacy index: drop the key from every entry and reload.
        let indexURL = dir.appendingPathComponent("index.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any] ?? [:]
        var entries = json["entries"] as? [[String: Any]] ?? []
        for i in entries.indices { entries[i].removeValue(forKey: "payloadByteSize") }
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: indexURL)

        let legacy = ClipboardStore(directory: dir)
        XCTAssertEqual(legacy.count, 1, "an index without the key still loads (no history lost on upgrade)")
        XCTAssertEqual(legacy.allEntries().first?.payloadByteSize, big.count,
                       "back-filled from the blob file's on-disk size")
    }

    // MARK: - Memory bound: large payloads leave residency once persisted

    /// After `flush()` a payload above the resident threshold is no longer held inline (memory is bounded
    /// even for this session's captures), yet the full bytes still materialize on demand for paste and the
    /// band's bounded preview still reads correctly from the blob.
    func testLargePayloadIsExternalizedFromMemoryAfterFlushButStillMaterializes() {
        let store = ClipboardStore(directory: tempDir())
        let big = String(repeating: "L", count: ClipboardStore.residentByteThreshold * 2)
        let id = UUID()
        store.insert(entry(big, at: 100, id: id))
        XCTAssertEqual(store.residentInlineBytes, big.utf8.count, "resident until the persist has landed")

        store.flush()

        XCTAssertEqual(store.residentInlineBytes, 0, "the large payload is swapped to its on-disk blob")
        XCTAssertEqual(store.materializedEntry(id: id)?.data(for: ClipboardUTI.plainText), Data(big.utf8),
                       "the full content still materializes for paste")
        let banded = store.bandWindow(limit: 1).first
        XCTAssertEqual(banded?.isPreviewTruncated, true)
        XCTAssertEqual(banded?.data(for: ClipboardUTI.plainText)?.count, ClipboardStore.previewByteCap,
                       "the band's bounded preview reads the blob prefix")
        XCTAssertEqual(store.allEntries().first?.payloadByteSize, big.utf8.count, "retention still counts it")
    }

    /// A payload between the blob threshold (on disk) and the resident threshold (in memory) stays inline —
    /// everyday text stays instant.
    func testMidSizedPayloadStaysResident() {
        let store = ClipboardStore(directory: tempDir())
        let mid = String(repeating: "M", count: ClipboardStore.residentByteThreshold / 2)
        store.insert(entry(mid, at: 100))
        store.flush()
        XCTAssertEqual(store.residentInlineBytes, mid.utf8.count, "not swapped out")
    }

    /// Pure: the swap only applies where the live bytes still equal what was written — a payload re-copied
    /// with different content between the snapshot and the persist keeps its inline bytes (its own save
    /// will externalize it), so a stale result can never point an entry at the wrong blob.
    func testAdoptingExternalizedSkipsPayloadsThatChangedSinceTheSnapshot() {
        let id = UUID()
        let snapshot = [ClipboardEntry(id: id, capturedAt: Date(timeIntervalSince1970: 1), kind: .text, key: "a",
                                       representations: [ClipboardUTI.plainText: .inline(Data(repeating: 1, count: 10))],
                                       fingerprint: "f")]
        var persisted = snapshot
        persisted[0].representations[ClipboardUTI.plainText] = .blob("a.bin")
        var live = snapshot
        live[0].representations[ClipboardUTI.plainText] = .inline(Data(repeating: 2, count: 10))   // changed
        let result = ClipboardStore.adoptingExternalized(live, snapshot: snapshot, persisted: persisted, threshold: 4)
        XCTAssertEqual(result[0].representations[ClipboardUTI.plainText], .inline(Data(repeating: 2, count: 10)))

        let unchanged = ClipboardStore.adoptingExternalized(snapshot, snapshot: snapshot, persisted: persisted, threshold: 4)
        XCTAssertEqual(unchanged[0].representations[ClipboardUTI.plainText], .blob("a.bin"), "matching bytes adopt the blob")
        let small = ClipboardStore.adoptingExternalized(snapshot, snapshot: snapshot, persisted: persisted, threshold: 100)
        XCTAssertEqual(small[0].representations[ClipboardUTI.plainText]?.inlineData?.count, 10, "below the threshold stays resident")
    }

    // MARK: - payloadSource: one representation, no blob read on the actor

    func testPayloadSourceResolvesInlineThenFileAfterExternalization() {
        let store = ClipboardStore(directory: tempDir())
        let big = Data(repeating: 0xCD, count: ClipboardStore.residentByteThreshold * 2)
        let id = UUID()
        store.insert(ClipboardEntry(id: id, capturedAt: Date(timeIntervalSince1970: 100), kind: .image, key: "Image",
                                    representations: [ClipboardUTI.png: .inline(big)], fingerprint: "img:1"))
        XCTAssertEqual(store.payloadSource(id: id, uti: ClipboardUTI.png), .inline(big))
        XCTAssertNil(store.payloadSource(id: id, uti: ClipboardUTI.tiff), "only the representations it has")
        XCTAssertNil(store.payloadSource(id: UUID(), uti: ClipboardUTI.png), "unknown id → nil")

        store.flush()

        guard case let .file(url)? = store.payloadSource(id: id, uti: ClipboardUTI.png) else {
            return XCTFail("after externalization the source is the blob file")
        }
        XCTAssertEqual(ClipboardPayloadSource.file(url).load(), big, "the file read (done off-main by callers) yields the bytes")
    }
}
