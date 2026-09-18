import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure `HostReadBackoff` (KeyboardLanguage/HostReadBackoff.swift): the negative-result
/// ladder that keeps the 0.5 s per-site poll from re-running an expensive, hopeless host read (the AX
/// address-bar walk / a failing Apple Event) on every tick. Time is an input, so the ladder is exact.
final class HostReadBackoffTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testFreshBackoffSkipsNothing() {
        let backoff = HostReadBackoff()
        XCTAssertFalse(backoff.shouldSkip("chrome:w1", now: t0))
        XCTAssertNil(backoff.missedKey)
    }

    func testFirstMissHoldsForTheInitialDelayThenRetries() {
        var backoff = HostReadBackoff(initialDelay: 2, maxDelay: 30)
        backoff.recordMiss("chrome:w1", now: t0)
        XCTAssertTrue(backoff.shouldSkip("chrome:w1", now: at(0.5)), "inside the hold → skip the read")
        XCTAssertTrue(backoff.shouldSkip("chrome:w1", now: at(1.99)))
        XCTAssertFalse(backoff.shouldSkip("chrome:w1", now: at(2)), "the hold expires → one real retry")
    }

    func testConsecutiveMissesDoubleUpToTheCap() {
        var backoff = HostReadBackoff(initialDelay: 2, maxDelay: 30)
        var now = t0
        var expected: [TimeInterval] = []
        for delay in [2.0, 4, 8, 16, 30, 30, 30] {
            backoff.recordMiss("chrome:w1", now: now)
            expected.append(delay)
            XCTAssertEqual(backoff.currentDelay, delay, accuracy: 0.001)
            XCTAssertTrue(backoff.shouldSkip("chrome:w1", now: now.addingTimeInterval(delay - 0.01)))
            XCTAssertFalse(backoff.shouldSkip("chrome:w1", now: now.addingTimeInterval(delay)))
            now = now.addingTimeInterval(delay)   // the retry at expiry misses again
        }
        XCTAssertEqual(expected, [2, 4, 8, 16, 30, 30, 30])
    }

    func testAnotherKeyIsNeverHeldAndStartsItsOwnLadder() {
        var backoff = HostReadBackoff(initialDelay: 2, maxDelay: 30)
        backoff.recordMiss("chrome:w1", now: t0)
        backoff.recordMiss("chrome:w1", now: at(2))   // now holding 4 s
        // A different focused window (or process) is a different key: it always gets a first read…
        XCTAssertFalse(backoff.shouldSkip("chrome:w2", now: at(3)))
        // …and its miss restarts at the initial delay (single slot: the old key's hold is dropped).
        backoff.recordMiss("chrome:w2", now: at(3))
        XCTAssertEqual(backoff.currentDelay, 2, accuracy: 0.001)
        XCTAssertEqual(backoff.missedKey, "chrome:w2")
        XCTAssertFalse(backoff.shouldSkip("chrome:w1", now: at(3.5)), "the previous key's hold is gone")
    }

    func testHitClearsTheHold() {
        var backoff = HostReadBackoff(initialDelay: 2, maxDelay: 30)
        backoff.recordMiss("chrome:w1", now: t0)
        backoff.recordMiss("chrome:w1", now: at(2))
        backoff.recordHit()
        XCTAssertFalse(backoff.shouldSkip("chrome:w1", now: at(2.1)))
        XCTAssertNil(backoff.missedKey)
        // The next miss after a hit starts over at the initial delay, not where the old ladder was.
        backoff.recordMiss("chrome:w1", now: at(3))
        XCTAssertEqual(backoff.currentDelay, 2, accuracy: 0.001)
    }

    func testResetIsTheAppActivationHook() {
        var backoff = HostReadBackoff(initialDelay: 2, maxDelay: 30)
        backoff.recordMiss("safari:w9", now: t0)
        XCTAssertTrue(backoff.shouldSkip("safari:w9", now: at(1)))
        backoff.reset()   // `HostProvider.noteAppSwitch`
        XCTAssertFalse(backoff.shouldSkip("safari:w9", now: at(1)), "a fresh visit re-tries the read once")
        XCTAssertEqual(backoff, HostReadBackoff(initialDelay: 2, maxDelay: 30))
    }

    func testDelaysAreSanitized() {
        let backoff = HostReadBackoff(initialDelay: -1, maxDelay: 0.5)
        XCTAssertEqual(backoff.initialDelay, 0)
        XCTAssertEqual(backoff.maxDelay, 0.5, "the cap is never below the initial delay")
        let inverted = HostReadBackoff(initialDelay: 5, maxDelay: 1)
        XCTAssertEqual(inverted.maxDelay, 5)
    }
}
