import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure decision logic of `SpacesRearrangeConfig` (no system access):
///   - `state(forRawValue:)`   — map a `defaults read` result to a State (absent ⇒ default ON).
///   - `backupToken(forRawValue:)` — what to persist as the backup, incl. the absent case.
///   - `restoreAction(forToken:)`  — what restoring a given backup token should do.
final class SpacesRearrangeConfigTests: XCTestCase {

    // MARK: - state(forRawValue:)

    func testAbsentValueMapsToRearrangingDefault() {
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: nil), .rearranging)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: ""), .rearranging)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "   \n"), .rearranging)
    }

    func testFalsyValuesMapToFixed() {
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "0"), .fixed)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "false"), .fixed)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "FALSE"), .fixed)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: " 0 \n"), .fixed, "whitespace is trimmed")
    }

    func testTruthyValuesMapToRearranging() {
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "1"), .rearranging)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "true"), .rearranging)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "True"), .rearranging)
    }

    func testUnrecognizedValueMapsToUnknown() {
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "2"), .unknown)
        XCTAssertEqual(SpacesRearrangeConfig.state(forRawValue: "yes"), .unknown)
    }

    // MARK: - backupToken(forRawValue:)

    func testBackupTokenForAbsentIsAbsent() {
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: nil), "absent")
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: ""), "absent")
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: "  "), "absent")
    }

    func testBackupTokenNormalizesBooleans() {
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: "1"), "1")
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: "true"), "1")
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: "TRUE"), "1")
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: "0"), "0")
        XCTAssertEqual(SpacesRearrangeConfig.backupToken(forRawValue: "false"), "0")
    }

    // MARK: - restoreAction(forToken:)

    func testRestoreActionForAbsentDeletesKey() {
        XCTAssertEqual(SpacesRearrangeConfig.restoreAction(forToken: "absent"), .delete)
    }

    func testRestoreActionForExplicitValuesWritesThemBack() {
        XCTAssertEqual(SpacesRearrangeConfig.restoreAction(forToken: "0"), .write(false))
        XCTAssertEqual(SpacesRearrangeConfig.restoreAction(forToken: "1"), .write(true))
    }

    func testRestoreActionForMissingBackupIsNone() {
        XCTAssertEqual(SpacesRearrangeConfig.restoreAction(forToken: nil), .none)
    }

    /// Round-trip: the state we back up should restore to the same effective state.
    /// Absent (default ON) backs up as "absent" and restores by deleting the key.
    func testAbsentRoundTripRestoresToDefault() {
        let token = SpacesRearrangeConfig.backupToken(forRawValue: nil)   // app saw default ON
        XCTAssertEqual(token, "absent")
        XCTAssertEqual(SpacesRearrangeConfig.restoreAction(forToken: token), .delete)
    }
}
