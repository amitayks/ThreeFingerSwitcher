import XCTest
@testable import ThreeFingerSwitcherCore

/// The pure identity-keyed restart decision behind the Files-band dwell-to-arm (change:
/// add-files-band-dwell-arm). The controller owns the timer + haptic; this verifies the *decision* that gates
/// them — the non-obvious bit being that an unchanged identity yields `.keep`, which is exactly why the
/// `+1`-finger morph (it moves no highlight) preserves the arm the user charged on the row.
final class FilesDwellArmingTests: XCTestCase {

    func testLandingOnARealRowRestarts() {
        var arming = FilesDwellArming()
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .restart)
        XCTAssertEqual(arming.lastIdentity, "/Home/Docs")
    }

    func testSameIdentityKeeps_thePlusOneFingerPreservesTheArm() {
        var arming = FilesDwellArming()
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .restart)
        // A `+1`-finger morph (then the lift) re-evaluates with the SAME highlighted row → no restart, so the
        // charge that already armed this row survives into the menu-open gate.
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .keep)
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .keep)
    }

    func testMovingToAnotherRowRestarts() {
        var arming = FilesDwellArming()
        _ = arming.update(identity: "/Home/Docs")
        XCTAssertEqual(arming.update(identity: "/Home/photo.png"), .restart)
        XCTAssertEqual(arming.update(identity: "/Home/photo.png"), .keep)
    }

    func testMovingOntoAnEmptyColumnDisarms() {
        var arming = FilesDwellArming()
        _ = arming.update(identity: "/Home/Docs")
        XCTAssertEqual(arming.update(identity: nil), .disarm)
        // Still nothing highlighted → nothing to (re)arm; keep (already disarmed).
        XCTAssertEqual(arming.update(identity: nil), .keep)
    }

    func testStartingOnNothingKeeps() {
        var arming = FilesDwellArming()
        XCTAssertEqual(arming.update(identity: nil), .keep, "nothing was armed, nothing to disarm")
    }

    func testSubColumnTransitionsEachRestart() {
        var arming = FilesDwellArming()
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .restart)   // folder row
        XCTAssertEqual(arming.update(identity: "menu:0"), .restart)        // entered the action menu
        XCTAssertEqual(arming.update(identity: "menu:1"), .restart)        // scrubbed a menu row
        XCTAssertEqual(arming.update(identity: "picker:2"), .restart)      // descended into the app grid
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .restart)    // backed out to the folder row
    }

    func testResetForcesAFreshChargeOnTheSameRow() {
        var arming = FilesDwellArming()
        _ = arming.update(identity: "/Home/Docs")
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .keep)
        // A delivery-failure re-arm in place: reset, then the SAME row must charge afresh (the user re-dwells).
        arming.reset()
        XCTAssertNil(arming.lastIdentity)
        XCTAssertEqual(arming.update(identity: "/Home/Docs"), .restart)
    }
}
