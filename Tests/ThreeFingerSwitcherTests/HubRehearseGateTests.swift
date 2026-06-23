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

    // MARK: - Pure gate: arm on ≥3, then drive on ≥2

    func testShouldArmRequiresThreeFingers() {
        XCTAssertFalse(HubRehearseGate.shouldArm(fingerCount: 0))
        XCTAssertFalse(HubRehearseGate.shouldArm(fingerCount: 1))
        XCTAssertFalse(HubRehearseGate.shouldArm(fingerCount: 2), "two fingers is a scroll, not a trigger")
        XCTAssertTrue(HubRehearseGate.shouldArm(fingerCount: 3), "three fingers arms a rehearsal")
        XCTAssertTrue(HubRehearseGate.shouldArm(fingerCount: 4))
    }

    func testGateClosedWhenNoActiveTarget() {
        // No preview focused → no rehearsal regardless of finger count or arm state.
        for fingers in 0...5 {
            XCTAssertFalse(HubRehearseGate.shouldDriveDots(isActiveTarget: false, armed: true, fingerCount: fingers))
            XCTAssertFalse(HubRehearseGate.ownsGestures(isActiveTarget: false, armed: true, fingerCount: fingers))
        }
    }

    func testNotArmedNeverDrivesOrOwns() {
        // Before a ≥3-finger trigger, even a two-finger move is left alone (the scroll passes through).
        for fingers in 0...2 {
            XCTAssertFalse(HubRehearseGate.shouldDriveDots(isActiveTarget: true, armed: false, fingerCount: fingers),
                           "an un-armed move must not drive (fingers \(fingers))")
            XCTAssertFalse(HubRehearseGate.ownsGestures(isActiveTarget: true, armed: false, fingerCount: fingers),
                           "an un-armed move must not own the gesture (fingers \(fingers))")
        }
    }

    func testArmedSingleFingerNeverDrivesOrOwns() {
        // Even armed, a single finger is ignored (no cursor-as-gesture).
        XCTAssertFalse(HubRehearseGate.shouldDriveDots(isActiveTarget: true, armed: true, fingerCount: 1))
        XCTAssertFalse(HubRehearseGate.ownsGestures(isActiveTarget: true, armed: true, fingerCount: 1))
    }

    func testArmedLiftNeverDrivesOrOwns() {
        XCTAssertFalse(HubRehearseGate.shouldDriveDots(isActiveTarget: true, armed: true, fingerCount: 0))
        XCTAssertFalse(HubRehearseGate.ownsGestures(isActiveTarget: true, armed: true, fingerCount: 0))
    }

    func testArmedTwoOrMoreFingersDrivesAndOwns() {
        for fingers in HubRehearseGate.minimumFingers...5 {
            XCTAssertTrue(HubRehearseGate.shouldDriveDots(isActiveTarget: true, armed: true, fingerCount: fingers),
                          "an armed ≥2-finger move must drive (fingers \(fingers))")
            XCTAssertTrue(HubRehearseGate.ownsGestures(isActiveTarget: true, armed: true, fingerCount: fingers),
                          "an armed ≥2-finger move must own the gesture (fingers \(fingers))")
        }
    }

    func testDriveAndOwnAreEquivalent() {
        // The two verdicts share one condition, so suppression and live-dots can never disagree.
        for target in [false, true] {
            for armed in [false, true] {
                for fingers in 0...5 {
                    XCTAssertEqual(
                        HubRehearseGate.shouldDriveDots(isActiveTarget: target, armed: armed, fingerCount: fingers),
                        HubRehearseGate.ownsGestures(isActiveTarget: target, armed: armed, fingerCount: fingers),
                        "drive and own must agree (target \(target), armed \(armed), fingers \(fingers))")
                }
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
    func testBareTwoFingerScrollIsNotSwallowed() {
        // A two-finger move with no preceding ≥3-finger trigger is an ordinary scroll — never swallowed,
        // so the Hub page keeps scrolling.
        let controller = HubRehearseController()
        controller.register(UUID())
        controller.ingest(fingerCount: 2, contacts: [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.6, y: 0.4)])
        XCTAssertNil(controller.liveDots, "an un-armed two-finger move drives nothing")
        XCTAssertFalse(controller.ownsGestures, "an un-armed two-finger move does not own the gesture (scroll passes)")
    }

    @MainActor
    func testThreeFingerTriggerThenRelaxToTwoDrivesAndOwns() {
        let controller = HubRehearseController()
        controller.register(UUID())
        // Three fingers ARM the rehearsal.
        controller.ingest(fingerCount: 3, contacts: [CGPoint(x: 0.2, y: 0.4),
                                                     CGPoint(x: 0.4, y: 0.4),
                                                     CGPoint(x: 0.6, y: 0.4)])
        XCTAssertTrue(controller.ownsGestures, "a three-finger trigger arms and owns the gesture")
        // Relaxing to two AFTER the trigger keeps driving (the real switcher grammar).
        let two = [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.6, y: 0.4)]
        controller.ingest(fingerCount: 2, contacts: two)
        XCTAssertEqual(controller.liveDots, two, "relaxing to two after the trigger keeps driving")
        XCTAssertTrue(controller.ownsGestures)
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
        controller.ingest(fingerCount: 3, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
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
        controller.ingest(fingerCount: 3, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.7, y: 0.5)])

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
        controller.ingest(fingerCount: 3, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
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
        // Mid-rehearsal (a focused preview, a ≥3-finger trigger down, owning the gesture)…
        let controller = HubRehearseController()
        controller.register(UUID())
        controller.ingest(fingerCount: 3, contacts: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
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
