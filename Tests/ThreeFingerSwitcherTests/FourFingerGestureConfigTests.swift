import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure decision logic of `FourFingerGestureConfig` (no system access):
///   - `horizState(forRawValue:)` — `1` == claimed by the OS (full-screen-app swipe on four
///     fingers); any other number == free; absent/unrecognized == unknown.
///   - `backupToken(forRawValue:)` / `restoreAction(forToken:)` — absent-aware backup/restore.
///
/// The horizontal keys use a different encoding than the vertical keys: `1` means "assigned to
/// this finger count" (per `TrackpadGestureConfig`, which writes the four-finger horiz key to `1`
/// to MOVE the swipe there). Freeing it for the launcher writes the unassigned value `2`.
final class FourFingerGestureConfigTests: XCTestCase {

    // MARK: - horizState

    func testValueOneIsClaimed() {
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: "1"), .claimedByFourFinger)
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: " 1 \n"), .claimedByFourFinger, "whitespace trimmed")
    }

    func testNonOneNumbersAreFree() {
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: "2"), .free)
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: "0"), .free)
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: " 2\n"), .free)
    }

    func testAbsentOrUnrecognizedIsUnknown() {
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: nil), .unknown)
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: ""), .unknown)
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: "  \n"), .unknown)
        XCTAssertEqual(FourFingerGestureConfig.horizState(forRawValue: "yes"), .unknown)
    }

    // MARK: - backupToken

    func testBackupTokenForAbsentIsAbsent() {
        XCTAssertEqual(FourFingerGestureConfig.backupToken(forRawValue: nil), "absent")
        XCTAssertEqual(FourFingerGestureConfig.backupToken(forRawValue: ""), "absent")
        XCTAssertEqual(FourFingerGestureConfig.backupToken(forRawValue: "notanint"), "absent")
    }

    func testBackupTokenNormalizesIntegers() {
        XCTAssertEqual(FourFingerGestureConfig.backupToken(forRawValue: "1"), "1")
        XCTAssertEqual(FourFingerGestureConfig.backupToken(forRawValue: " 2 \n"), "2")
        XCTAssertEqual(FourFingerGestureConfig.backupToken(forRawValue: "0"), "0")
    }

    // MARK: - restoreAction

    func testRestoreActionForAbsentDeletesKey() {
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: "absent"), .delete)
    }

    func testRestoreActionForExplicitValuesWritesThemBack() {
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: "1"), .write(1))
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: "2"), .write(2))
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: " 0 \n"), .write(0))
    }

    func testRestoreActionForMissingOrJunkTokenIsNone() {
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: nil), .none)
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: "garbage"), .none)
    }

    // MARK: - Round-trips

    /// A four-finger horizontal swipe claimed (value 1) backs up as "1" and restores by writing 1.
    func testClaimedRoundTripRestoresToOne() {
        let token = FourFingerGestureConfig.backupToken(forRawValue: "1")
        XCTAssertEqual(token, "1")
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: token), .write(1))
    }

    /// An absent key backs up as "absent" and restores by deleting it (faithful to the default).
    func testAbsentRoundTripDeletesKey() {
        let token = FourFingerGestureConfig.backupToken(forRawValue: nil)
        XCTAssertEqual(token, "absent")
        XCTAssertEqual(FourFingerGestureConfig.restoreAction(forToken: token), .delete)
    }
}
