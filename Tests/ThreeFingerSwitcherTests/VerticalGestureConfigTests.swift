import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure decision logic of `VerticalGestureConfig` (no system access):
///   - `threeFingerState(forRawValue:)` — map a `defaults read` of the three-finger vertical key
///     to a State (2 = claimed by the OS, 0 = free, absent/other = unknown).
///   - `backupToken(forRawValue:)`       — what to persist as the backup, incl. the absent case.
///   - `restoreAction(forToken:)`         — what restoring a given backup token should do.
///
/// Value semantics come from an authoritative on-machine `defaults` diff: switching Mission
/// Control / App Exposé from three to four fingers flips `TrackpadThreeFingerVertSwipeGesture`
/// from `2` to `0` (and nothing else), so `2` == claimed (three-finger) and `0` == free.
final class VerticalGestureConfigTests: XCTestCase {

    // MARK: - threeFingerState(forRawValue:)

    func testValueTwoIsClaimedByThreeFinger() {
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: "2"), .claimedByThreeFinger)
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: " 2 \n"), .claimedByThreeFinger, "whitespace is trimmed")
    }

    func testValueZeroIsFree() {
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: "0"), .free)
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: " 0\n"), .free)
    }

    func testAbsentOrUnrecognizedIsUnknown() {
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: nil), .unknown)
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: ""), .unknown)
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: "   \n"), .unknown)
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: "1"), .unknown)
        XCTAssertEqual(VerticalGestureConfig.threeFingerState(forRawValue: "yes"), .unknown)
    }

    // MARK: - backupToken(forRawValue:)

    func testBackupTokenForAbsentIsAbsent() {
        XCTAssertEqual(VerticalGestureConfig.backupToken(forRawValue: nil), "absent")
        XCTAssertEqual(VerticalGestureConfig.backupToken(forRawValue: ""), "absent")
        XCTAssertEqual(VerticalGestureConfig.backupToken(forRawValue: "  "), "absent")
        XCTAssertEqual(VerticalGestureConfig.backupToken(forRawValue: "notanint"), "absent")
    }

    func testBackupTokenNormalizesIntegers() {
        XCTAssertEqual(VerticalGestureConfig.backupToken(forRawValue: "2"), "2")
        XCTAssertEqual(VerticalGestureConfig.backupToken(forRawValue: " 2 \n"), "2", "whitespace is trimmed")
        XCTAssertEqual(VerticalGestureConfig.backupToken(forRawValue: "0"), "0")
    }

    // MARK: - restoreAction(forToken:)

    func testRestoreActionForAbsentDeletesKey() {
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: "absent"), .delete)
    }

    func testRestoreActionForExplicitValuesWritesThemBack() {
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: "2"), .write(2))
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: "0"), .write(0))
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: " 2 \n"), .write(2), "whitespace is trimmed")
    }

    func testRestoreActionForMissingOrJunkTokenIsNone() {
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: nil), .none)
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: "garbage"), .none)
    }

    // MARK: - Round-trips

    /// The common default (three-finger active, value 2) backs up as "2" and restores by writing 2.
    func testClaimedRoundTripRestoresToTwo() {
        let token = VerticalGestureConfig.backupToken(forRawValue: "2")
        XCTAssertEqual(token, "2")
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: token), .write(2))
    }

    /// An absent key backs up as "absent" and restores by deleting the key (faithful to default).
    func testAbsentRoundTripDeletesKey() {
        let token = VerticalGestureConfig.backupToken(forRawValue: nil)
        XCTAssertEqual(token, "absent")
        XCTAssertEqual(VerticalGestureConfig.restoreAction(forToken: token), .delete)
    }
}
