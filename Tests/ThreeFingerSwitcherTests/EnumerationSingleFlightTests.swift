import XCTest
@testable import ThreeFingerSwitcherCore

/// The single-flight `SCShareableContent` enumeration: bounds and cache policy (pure parts).
@MainActor
final class EnumerationSingleFlightTests: XCTestCase {
    /// A caller must stop waiting before the sweep watchdog fires, or the watchdog supersedes a sweep
    /// that is only waiting for a slow (healthy) enumeration.
    func testCallerWaitIsBelowSweepWatchdog() {
        XCTAssertLessThan(ThumbnailService.enumerationWait, ThumbnailService.sweepStaleAfter)
    }

    /// The hung-ceiling must exceed the caller wait (else a slow enumeration is abandoned before anyone
    /// stops waiting for it) and the measured slow case (3.5 s with ~9,000 leaked windows).
    func testHungCeilingExceedsWaitAndMeasuredSlowCase() {
        XCTAssertGreaterThan(ThumbnailService.enumerationCeiling, ThumbnailService.enumerationWait)
        XCTAssertGreaterThan(ThumbnailService.enumerationCeiling, 3.5 * 3)
    }

    func testRunningEnumerationIsJoinedUntilCeiling() {
        XCTAssertFalse(ThumbnailService.isEnumerationHung(startedAt: 100, now: 100))
        XCTAssertFalse(ThumbnailService.isEnumerationHung(startedAt: 100, now: 103.5))
        XCTAssertTrue(ThumbnailService.isEnumerationHung(startedAt: 100, now: 100 + ThumbnailService.enumerationCeiling))
    }

    func testCacheDecision() {
        typealias T = ThumbnailService
        XCTAssertEqual(T.cacheDecision(age: nil, covers: true, ttl: 3), .miss)
        XCTAssertEqual(T.cacheDecision(age: 1, covers: false, ttl: 3), .miss)     // new window: must enumerate
        XCTAssertEqual(T.cacheDecision(age: 1, covers: true, ttl: 3), .fresh)
        XCTAssertEqual(T.cacheDecision(age: 5, covers: true, ttl: 3), .stale)     // serve + refresh behind
        XCTAssertEqual(T.cacheDecision(age: T.staleContentLimit, covers: true, ttl: 3), .miss)
    }

    func testTopWindowOwnersFlagsLeak() {
        let owners = Array(repeating: "CursorUIViewService", count: 1_500) + ["Finder", "Finder", "Dock"]
        let top = ThumbnailService.topWindowOwners(owners, limit: 2)
        XCTAssertEqual(top.map(\.owner), ["CursorUIViewService", "Finder"])
        XCTAssertEqual(top.first?.count, 1_500)
        XCTAssertGreaterThan(top[0].count, ThumbnailService.leakedWindowThreshold)
    }
}
