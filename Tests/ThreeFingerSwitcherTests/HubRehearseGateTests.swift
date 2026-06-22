import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for the Hub gesture-preview **rehearse** seam (§2.3 / §2.4 of
/// `add-gesture-previews-and-bindings`): the pure `HubRehearseGate` ≥2-finger / ownership verdict and the
/// `HubRehearseController` lifecycle that drives the live `liveDots` + recognizer-suppression gate.
///
/// Contract under test:
///   - The gate opens ONLY when a preview is the active target AND ≥2 fingers are down.
///   - A single-finger move (or a lift) never drives the preview and never owns the gesture.
///   - `ownsGestures` (recognizer suppression) tracks the same condition, so rehearsing never fires the
///     real feature, and resumes the instant the fingers lift or the preview loses focus.
final class HubRehearseGateTests: XCTestCase {

    // MARK: - Pure gate: the ≥2-finger decision

    func testGateClosedWhenNoActiveTarget() {
        // No preview focused → no rehearsal regardless of finger count.
        for fingers in 0...5 {
            XCTAssertFalse(HubRehearseGate.shouldDriveDots(isActiveTarget: false, fingerCount: fingers),
                           "no active target must never drive dots (fingers \(fingers))")
            XCTAssertFalse(HubRehearseGate.ownsGestures(isActiveTarget: false, fingerCount: fingers),
                           "no active target must never own the gesture (fingers \(fingers))")
        }
    }

    func testSingleFingerNeverDrivesOrOwns() {
        // A one-finger move is ignored entirely even with a focused preview (no cursor-as-gesture).
        XCTAssertFalse(HubRehearseGate.shouldDriveDots(isActiveTarget: true, fingerCount: 1))
        XCTAssertFalse(HubRehearseGate.ownsGestures(isActiveTarget: true, fingerCount: 1))
    }

    func testLiftNeverDrivesOrOwns() {
        // Fingers fully lifted (count 0) closes the gate so the real recognizer resumes.
        XCTAssertFalse(HubRehearseGate.shouldDriveDots(isActiveTarget: true, fingerCount: 0))
        XCTAssertFalse(HubRehearseGate.ownsGestures(isActiveTarget: true, fingerCount: 0))
    }

    func testTwoOrMoreFingersWithActiveTargetDrivesAndOwns() {
        for fingers in HubRehearseGate.minimumFingers...5 {
            XCTAssertTrue(HubRehearseGate.shouldDriveDots(isActiveTarget: true, fingerCount: fingers),
                          "≥2 fingers with an active target must drive dots (fingers \(fingers))")
            XCTAssertTrue(HubRehearseGate.ownsGestures(isActiveTarget: true, fingerCount: fingers),
                          "≥2 fingers with an active target must own the gesture (fingers \(fingers))")
        }
    }

    func testDriveAndOwnAreEquivalent() {
        // The two verdicts share one condition: the Hub owns the gesture for exactly the frames it drives
        // a rehearsed preview, so suppression and live-dots can never disagree.
        for target in [false, true] {
            for fingers in 0...5 {
                XCTAssertEqual(HubRehearseGate.shouldDriveDots(isActiveTarget: target, fingerCount: fingers),
                               HubRehearseGate.ownsGestures(isActiveTarget: target, fingerCount: fingers),
                               "drive and own must agree (target \(target), fingers \(fingers))")
            }
        }
    }

    // MARK: - Controller: registration + ingest lifecycle

    @MainActor
    func testFreshControllerHasNoTargetAndDoesNotOwn() {
        let controller = HubRehearseController()
        XCTAssertNil(controller.activeTarget)
        XCTAssertNil(controller.liveDots)
        XCTAssertFalse(controller.ownsGestures, "no registered preview ⇒ never owns the gesture")
    }

    @MainActor
    func testRegisteredTargetWithTwoFingersDrivesDotsAndOwns() {
        let controller = HubRehearseController()
        let token = UUID()
        controller.register(token)

        let dots = [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.6, y: 0.4)]
        controller.ingest(fingerCount: 2, contacts: dots)

        XCTAssertEqual(controller.liveDots, dots, "≥2 contacts feed straight through to liveDots")
        XCTAssertTrue(controller.ownsGestures, "rehearsing with 2 fingers owns the gesture")
    }

    @MainActor
    func testRegisteredTargetWithOneFingerIgnored() {
        let controller = HubRehearseController()
        controller.register(UUID())
        controller.ingest(fingerCount: 1, contacts: [CGPoint(x: 0.5, y: 0.5)])

        XCTAssertNil(controller.liveDots, "a single finger never drives the preview")
        XCTAssertFalse(controller.ownsGestures, "a single finger never owns the gesture")
    }

    @MainActor
    func testLiftClearsDotsAndReleasesOwnership() {
        let controller = HubRehearseController()
        let token = UUID()
        controller.register(token)
        controller.ingest(fingerCount: 3, contacts: [CGPoint(x: 0.2, y: 0.2),
                                                      CGPoint(x: 0.4, y: 0.2),
                                                      CGPoint(x: 0.6, y: 0.2)])
        XCTAssertTrue(controller.ownsGestures)

        // Fingers lift (empty frame): the gate must close so normal recognizer feeding resumes.
        controller.ingest(fingerCount: 0, contacts: [])
        XCTAssertNil(controller.liveDots)
        XCTAssertFalse(controller.ownsGestures, "after a lift the Hub must not own the gesture")
    }

    @MainActor
    func testUnregisterReleasesOwnershipEvenWithFingersDown() {
        let controller = HubRehearseController()
        let token = UUID()
        controller.register(token)
        controller.ingest(fingerCount: 2, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        XCTAssertTrue(controller.ownsGestures)

        // The preview loses focus / disappears while fingers are still down: the gate must close so the
        // real recognizer is never left dead (the missed-exit risk in the design).
        controller.unregister(token)
        XCTAssertNil(controller.activeTarget)
        XCTAssertNil(controller.liveDots)
        XCTAssertFalse(controller.ownsGestures, "blur must immediately release gesture ownership")
    }

    @MainActor
    func testUnregisterOfNonActiveTargetIsNoOp() {
        let controller = HubRehearseController()
        let active = UUID()
        controller.register(active)
        controller.ingest(fingerCount: 2, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])

        // A late disappear from a previously-superseded preview must not tear down the active one.
        controller.unregister(UUID())
        XCTAssertEqual(controller.activeTarget, active)
        XCTAssertTrue(controller.ownsGestures, "a stale unregister must not release the active rehearsal")
    }

    @MainActor
    func testRegisteringNewTargetSupersedesAndClearsStaleDots() {
        let controller = HubRehearseController()
        let first = UUID()
        controller.register(first)
        controller.ingest(fingerCount: 2, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        XCTAssertNotNil(controller.liveDots)

        // Switching pages focuses a new preview: it becomes the target and starts from the ghost loop.
        let second = UUID()
        controller.register(second)
        XCTAssertEqual(controller.activeTarget, second)
        XCTAssertNil(controller.liveDots, "a freshly focused preview starts with no carried-over dots")
        XCTAssertFalse(controller.ownsGestures, "a fresh target with no frame yet does not own the gesture")
    }

    @MainActor
    func testResetFullyClosesGateWhenHubLeavesScreen() {
        // Mid-rehearsal (a focused preview, fingers down, owning the gesture)…
        let controller = HubRehearseController()
        controller.register(UUID())
        controller.ingest(fingerCount: 2, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        XCTAssertTrue(controller.ownsGestures)
        XCTAssertNotNil(controller.liveDots)

        // …the Hub leaves the screen (close / miniaturize). `reset()` must forget the target and all
        // in-flight state so nothing lingers even if the preview's `.onDisappear` never fired.
        controller.reset()
        XCTAssertNil(controller.activeTarget, "reset forgets the active target")
        XCTAssertNil(controller.liveDots, "reset clears any live dots")
        XCTAssertFalse(controller.ownsGestures, "after reset the Hub must not own the gesture")
    }
}
