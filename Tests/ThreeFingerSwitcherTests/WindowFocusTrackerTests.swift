import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Pure-state unit tests for `WindowFocusTracker` — the per-`CGWindowID` focus-recency history that
/// drives the switcher's primary sort key (from Sources/.../Windows/WindowFocusTracker.swift).
///
/// These exercise only the in-memory `order` state via `promote` / `rank` / `evict`; the live AX
/// observer and app-activation sources need real Accessibility and a frontmost app, so they are out
/// of scope here (covered by the user-run manual check in tasks.md 6.2).
///
/// `WindowFocusTracker` is `@MainActor`, so every test method that touches it is `@MainActor`.
final class WindowFocusTrackerTests: XCTestCase {

    // MARK: - promote / move-to-front

    @MainActor
    func testPromotePutsWindowAtFront() {
        // Arrange
        let tracker = WindowFocusTracker()

        // Act: promote in order 1, 2, 3 — the last promoted is most recent.
        tracker.promote(1)
        tracker.promote(2)
        tracker.promote(3)

        // Assert: front of the array is the most recent.
        XCTAssertEqual(tracker.order, [3, 2, 1])
    }

    @MainActor
    func testPromoteExistingWindowMovesItToFrontWithoutDuplicating() {
        // Arrange: build a history, then re-focus an older window.
        let tracker = WindowFocusTracker()
        tracker.promote(1)
        tracker.promote(2)
        tracker.promote(3)

        // Act: re-promote 1 (the oldest) — it should jump to front, not duplicate.
        tracker.promote(1)

        // Assert
        XCTAssertEqual(tracker.order, [1, 3, 2], "Re-focusing an older window moves it to front")
        XCTAssertEqual(tracker.order.count, 3, "No duplicate id is introduced")
    }

    @MainActor
    func testRePromotingFrontWindowIsIdempotent() {
        // Arrange
        let tracker = WindowFocusTracker()
        tracker.promote(1)
        tracker.promote(2)
        let before = tracker.order

        // Act: re-promote the already-front window.
        tracker.promote(2)

        // Assert: order unchanged.
        XCTAssertEqual(tracker.order, before, "Re-promoting the front window is a no-op")
    }

    // MARK: - rank semantics (index vs Int.max)

    @MainActor
    func testRankIsIndexForKnownWindowsAndMaxForUnknown() {
        // Arrange
        let tracker = WindowFocusTracker()
        tracker.promote(10)   // most recent -> rank 0
        tracker.promote(20)   // -> would be rank 0 after this
        tracker.promote(30)

        // After 10,20,30 the order is [30, 20, 10].
        // Assert: known ids rank by their index (lower = more recent).
        XCTAssertEqual(tracker.rank(30), 0, "Most-recently focused ranks 0")
        XCTAssertEqual(tracker.rank(20), 1)
        XCTAssertEqual(tracker.rank(10), 2)

        // Unknown ids sort after all known ones.
        XCTAssertEqual(tracker.rank(999), Int.max, "Never-focused window ranks Int.max")
    }

    @MainActor
    func testRankOnEmptyTrackerIsMax() {
        // Arrange
        let tracker = WindowFocusTracker()

        // Assert
        XCTAssertEqual(tracker.rank(1), Int.max, "Any id is unknown on a fresh tracker")
    }

    // MARK: - eviction to live ids

    @MainActor
    func testEvictKeepsOnlyLiveWindows() {
        // Arrange
        let tracker = WindowFocusTracker()
        tracker.promote(1)
        tracker.promote(2)
        tracker.promote(3)

        // Act: only ids 1 and 3 are still enumerated (2 closed).
        tracker.evict(keepingLive: [1, 3])

        // Assert: the closed id is gone; relative order of survivors is preserved.
        XCTAssertEqual(tracker.order, [3, 1], "Evicts the closed id, keeps survivors in order")
        XCTAssertEqual(tracker.rank(2), Int.max, "Evicted id is unknown afterwards")
        XCTAssertEqual(tracker.rank(3), 0)
        XCTAssertEqual(tracker.rank(1), 1)
    }

    @MainActor
    func testEvictWithEmptyLiveSetClearsHistory() {
        // Arrange
        let tracker = WindowFocusTracker()
        tracker.promote(1)
        tracker.promote(2)

        // Act: nothing is live (all windows closed).
        tracker.evict(keepingLive: [])

        // Assert
        XCTAssertTrue(tracker.order.isEmpty, "An empty live set clears the whole history")
    }

    @MainActor
    func testEvictDoesNotResurrectUnknownIds() {
        // Arrange
        let tracker = WindowFocusTracker()
        tracker.promote(1)

        // Act: a live set listing ids never focused must not add them to the history.
        tracker.evict(keepingLive: [1, 2, 3])

        // Assert: only the previously-known id remains.
        XCTAssertEqual(tracker.order, [1], "Eviction only prunes; it never inserts new ids")
    }
}
