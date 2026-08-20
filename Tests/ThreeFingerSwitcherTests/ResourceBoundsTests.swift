import XCTest
import AppKit
@testable import ThreeFingerSwitcherCore

/// Guards the bounded-resource behavior added by `fix-progressive-cpu-degradation`: the
/// thumbnail cache is a true LRU pruned to live windows, and the MRU tracker forgets dead pids.
/// These are the accumulation bugs that made the app slower the longer it ran — keep them pinned.
@MainActor
final class ResourceBoundsTests: XCTestCase {

    private func image() -> NSImage { NSImage(size: NSSize(width: 2, height: 2)) }

    // MARK: - ThumbnailService cache

    func testRetainOnlyDropsFramesOfClosedWindows() {
        let service = ThumbnailService()
        service.inject(image(), for: 1)
        service.inject(image(), for: 2)
        service.inject(image(), for: 3)

        service.retain(only: [1, 3])

        XCTAssertNotNil(service.cached(1))
        XCTAssertNil(service.cached(2), "a window no longer enumerated must not keep pinning its frame")
        XCTAssertNotNil(service.cached(3))
    }

    func testRetainOnlyIgnoresAnEmptyLiveSet() {
        let service = ThumbnailService()
        service.inject(image(), for: 1)

        service.retain(only: [])   // an enumeration hiccup must never wipe the last-good-frame store

        XCTAssertNotNil(service.cached(1))
    }

    func testReStoreRefreshesEvictionOrder() {
        // The cache holds 64 frames. Fill it, touch the OLDEST again, then overflow by one: a true
        // LRU evicts the second-oldest (id 2); the previous FIFO evicted id 1 even though it was
        // just refreshed — which let long-dead windows outlive actively-refreshed ones.
        let service = ThumbnailService()
        for id in 1...64 { service.inject(image(), for: CGWindowID(id)) }
        service.inject(image(), for: 1)
        service.inject(image(), for: 65)

        XCTAssertNotNil(service.cached(1), "a re-stored frame must be treated as most recently used")
        XCTAssertNil(service.cached(2), "the least recently stored frame is the one evicted")
        XCTAssertNotNil(service.cached(65))
    }

    func testInjectNotifiesObserver() {
        let service = ThumbnailService()
        var delivered: [CGWindowID] = []
        service.onThumbnail = { id, _ in delivered.append(id) }

        service.inject(image(), for: 7)

        XCTAssertEqual(delivered, [7])
        XCTAssertNotNil(service.cached(7))
    }

    // MARK: - MRUTracker

    func testEvictForgetsDeadPidsAndKeepsRelativeOrder() {
        let mru = MRUTracker()
        mru.promote(10)
        mru.promote(20)
        mru.promote(30)   // order: 30, 20, 10

        mru.evict(keepingLive: [10, 30])

        XCTAssertEqual(mru.rank(30), 0)
        XCTAssertEqual(mru.rank(10), 1)
        XCTAssertEqual(mru.rank(20), Int.max, "an exited app's pid must not linger in the MRU order")
        XCTAssertEqual(mru.order, [30, 10])
    }

    func testStartIsIdempotent() {
        // A second start() without stop() must not stack a second activation observer; stop()
        // must then fully tear down (a third start() re-arms from clean).
        let mru = MRUTracker()
        mru.start()
        mru.start()
        mru.stop()
        mru.start()
        mru.stop()
        // No observable crash/leak surface beyond "doesn't throw"; the guard is the contract.
    }
}
