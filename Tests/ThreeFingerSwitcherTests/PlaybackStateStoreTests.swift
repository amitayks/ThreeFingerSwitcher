import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for `PlaybackStateStore` (spec media-player: "Per-file resume of playback state"): the pure
/// resume rule (threshold / near-end), the size+mtime identity tiebreak (a moved/edited file starts
/// fresh), LRU eviction, and save/load round-trip against an injected temp directory.
@MainActor
final class PlaybackStateStoreTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-player-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func state(position: TimeInterval, duration: TimeInterval = 100,
                       size: Int64 = 1000, mtime: Date? = Date(timeIntervalSince1970: 1000),
                       lastOpened: Date = Date(timeIntervalSince1970: 5000)) -> PlaybackState {
        PlaybackState(resumePosition: position, duration: duration, audioTrackID: nil,
                      subtitleTrackID: nil, volume: 1.0, rate: 1.0, lastOpened: lastOpened,
                      fileSize: size, modificationDate: mtime)
    }

    // MARK: - Pure resume rule

    func testResumesPastThresholdAndBeforeNearEnd() {
        let pos = PlaybackStateStore.resumePosition(savedPosition: 50, duration: 100,
                                                    threshold: 5, nearEndMargin: 10)
        XCTAssertEqual(pos, 50)
    }

    func testStartsFreshBeforeThreshold() {
        let pos = PlaybackStateStore.resumePosition(savedPosition: 3, duration: 100,
                                                    threshold: 5, nearEndMargin: 10)
        XCTAssertEqual(pos, 0)
    }

    func testStartsFreshWithinNearEndMargin() {
        let pos = PlaybackStateStore.resumePosition(savedPosition: 95, duration: 100,
                                                    threshold: 5, nearEndMargin: 10)
        XCTAssertEqual(pos, 0)
    }

    // MARK: - Identity tiebreak

    func testMatchingIdentityResumes() {
        let store = PlaybackStateStore(directory: tempDir())
        let mtime = Date(timeIntervalSince1970: 1000)
        store.record(path: "/m/a.mp4", state: state(position: 42, size: 2048, mtime: mtime))
        let got = store.state(forPath: "/m/a.mp4", size: 2048, modificationDate: mtime)
        XCTAssertEqual(got?.resumePosition, 42)
    }

    func testMovedOrEditedFileStartsFresh() {
        let store = PlaybackStateStore(directory: tempDir())
        store.record(path: "/m/a.mp4", state: state(position: 42, size: 2048,
                                                     mtime: Date(timeIntervalSince1970: 1000)))
        // Same path, different size → identity mismatch → no resume.
        XCTAssertNil(store.state(forPath: "/m/a.mp4", size: 9999,
                                 modificationDate: Date(timeIntervalSince1970: 1000)))
        // Same path+size, different mtime → mismatch.
        XCTAssertNil(store.state(forPath: "/m/a.mp4", size: 2048,
                                 modificationDate: Date(timeIntervalSince1970: 8888)))
    }

    // MARK: - LRU eviction

    func testEvictsLeastRecentlyOpenedBeyondCap() {
        var states: [String: PlaybackState] = [:]
        for i in 0..<10 {
            states["/m/\(i).mp4"] = state(position: 10, lastOpened: Date(timeIntervalSince1970: Double(i)))
        }
        let kept = PlaybackStateStore.evict(states, cap: 3)
        XCTAssertEqual(kept.count, 3)
        // The three most-recent (7,8,9) survive; the oldest are gone.
        XCTAssertNotNil(kept["/m/9.mp4"])
        XCTAssertNotNil(kept["/m/8.mp4"])
        XCTAssertNotNil(kept["/m/7.mp4"])
        XCTAssertNil(kept["/m/0.mp4"])
    }

    // MARK: - Persistence round-trip

    func testSaveLoadRoundTrip() {
        let dir = tempDir()
        let mtime = Date(timeIntervalSince1970: 1000)
        do {
            let store = PlaybackStateStore(directory: dir)
            store.record(path: "/m/a.mp4", state: state(position: 33, size: 100, mtime: mtime))
        }
        // A fresh store over the same directory reloads the persisted state.
        let reloaded = PlaybackStateStore(directory: dir)
        XCTAssertEqual(reloaded.state(forPath: "/m/a.mp4", size: 100, modificationDate: mtime)?.resumePosition, 33)
    }
}
