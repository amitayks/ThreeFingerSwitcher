import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for `ReloginMarkers` (NativeGesture/ReloginMarkers.swift): the persisted
/// pending-re-login state keyed on the login-session (audit session) identity. The point of the
/// design: an app relaunch within the same session keeps a relocation PENDING (the historic
/// in-memory flag faked "effective" there), and only a real re-login clears it.
final class ReloginMarkersTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var session: MutableLoginSession!
    private var markers: ReloginMarkers!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.ReloginMarkers.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        precondition(defaults != nil, "Failed to create isolated UserDefaults suite")
        session = MutableLoginSession(id: 7)
        markers = ReloginMarkers(defaults: defaults, session: session)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAbsentMarkerIsNotPending() {
        // Migration: an existing install with relocations applied long ago has no marker — it must
        // read as effective, never regress to pending.
        XCTAssertFalse(markers.isPending(.horizontal))
        XCTAssertFalse(markers.isPending(.spaceRows))
        XCTAssertFalse(markers.isPending(.launcher))
    }

    func testPendingWithinTheSameSession() {
        markers.markPending(.spaceRows)
        XCTAssertTrue(markers.isPending(.spaceRows))
        // A new ReloginMarkers instance over the same store (≈ app relaunch, same session)
        // still reads pending — the in-memory flag never survived this.
        let relaunched = ReloginMarkers(defaults: defaults, session: session)
        XCTAssertTrue(relaunched.isPending(.spaceRows))
    }

    func testRealReloginClearsOnRead() {
        markers.markPending(.launcher)
        session.id = 8   // logout/login: new audit session
        XCTAssertFalse(markers.isPending(.launcher))
        // Cleared on sight: back in the original session it stays cleared.
        session.id = 7
        XCTAssertFalse(markers.isPending(.launcher))
    }

    func testSweepClearsOnlyOtherSessionsMarkers() {
        markers.markPending([.horizontal, .spaceRows])
        session.id = 9
        markers.markPending(.launcher)   // written in the NEW session
        markers.sweepAtLaunch()
        XCTAssertFalse(markers.isPending(.horizontal), "previous session's marker swept")
        XCTAssertFalse(markers.isPending(.spaceRows))
        XCTAssertTrue(markers.isPending(.launcher), "current session's marker kept")
    }

    func testFastUserSwitchKeepsPending() {
        // Switching to another user and back never changes the original session's ASID, so the
        // marker correctly stays pending (the safe direction).
        markers.markPending(.spaceRows)
        markers.sweepAtLaunch()
        XCTAssertTrue(markers.isPending(.spaceRows))
    }

    func testUnknownWriterSessionBehavesLikeTheOldInMemoryFlag() {
        session.id = nil                 // ASID unreadable at write time
        markers.markPending(.horizontal)
        XCTAssertTrue(markers.isPending(.horizontal), "pending now")
        session.id = 7
        markers.sweepAtLaunch()          // next launch
        XCTAssertFalse(markers.isPending(.horizontal), "cleared by the launch sweep, like the old flag")
    }

    func testUnreadableCurrentSessionErrsPendingSide() {
        markers.markPending(.launcher)
        session.id = nil
        XCTAssertTrue(markers.isPending(.launcher))
        markers.sweepAtLaunch()
        XCTAssertTrue(markers.isPending(.launcher), "sweep keeps a real marker when it cannot verify the session")
    }

    func testClear() {
        markers.markPending(.all)
        markers.clear(.spaceRows)
        XCTAssertTrue(markers.isPending(.horizontal))
        XCTAssertFalse(markers.isPending(.spaceRows))
        XCTAssertTrue(markers.isPending(.launcher))
    }
}
