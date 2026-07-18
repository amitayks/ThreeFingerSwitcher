import XCTest
@testable import ThreeFingerSwitcherCore

/// `voice-double-tap-dwell-trigger`: the double-tap-then-hold trigger grammar. Every spec scenario
/// is a transition path here: tap+tap-hold talks, long single holds are plain modifier use, bare
/// double-taps are no-ops, chords can never trigger voice, and the capture stack is untouched until
/// dwell-elapsed.
final class PTTArmingModelTests: XCTestCase {

    private var model = PTTArmingModel()

    func testDoubleTapAndHoldTalksThenReleaseSends() {
        XCTAssertEqual(model.handle(.pttFlagDown), [.schedule(.tapMax)])
        XCTAssertEqual(model.phase, .firstDown)
        XCTAssertEqual(model.handle(.pttFlagUp), [.cancelTimer, .schedule(.gap)])
        XCTAssertEqual(model.phase, .awaitingSecond)
        XCTAssertEqual(model.handle(.pttFlagDown), [.cancelTimer, .schedule(.dwell)])
        XCTAssertEqual(model.phase, .dwelling)
        XCTAssertEqual(model.handle(.timerFired), [.firePTTDown], "capture begins ONLY at dwell-elapsed")
        XCTAssertEqual(model.phase, .held)
        XCTAssertEqual(model.handle(.pttFlagUp), [.firePTTUp])
        XCTAssertEqual(model.phase, .idle)
    }

    func testLongSingleHoldIsPlainModifierUse() {
        _ = model.handle(.pttFlagDown)
        XCTAssertEqual(model.handle(.timerFired), [], "tap-max elapsed: not a click — stand down")
        XCTAssertEqual(model.phase, .inert)
        XCTAssertEqual(model.handle(.pttFlagUp), [])
        XCTAssertEqual(model.phase, .idle, "release restores idle with no pending state")
    }

    func testBareDoubleTapIsANoOp() {
        _ = model.handle(.pttFlagDown)
        _ = model.handle(.pttFlagUp)
        _ = model.handle(.pttFlagDown)
        XCTAssertEqual(model.phase, .dwelling)
        XCTAssertEqual(model.handle(.pttFlagUp), [.cancelTimer], "released before the dwell: nothing fires")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.handle(.timerFired), [], "a late dwell timer is inert")
    }

    func testGapExpiryReturnsToIdle() {
        _ = model.handle(.pttFlagDown)
        _ = model.handle(.pttFlagUp)
        XCTAssertEqual(model.phase, .awaitingSecond)
        XCTAssertEqual(model.handle(.timerFired), [], "no second tap came")
        XCTAssertEqual(model.phase, .idle)
    }

    func testOptionDeleteChordNeverTriggersAtAnyStage() {
        // Chord during the FIRST press (⌥⌫ delete-word — the original regression).
        _ = model.handle(.pttFlagDown)
        XCTAssertEqual(model.handle(.otherKeyDown), [.cancelTimer])
        XCTAssertEqual(model.phase, .inert)
        _ = model.handle(.pttFlagUp)

        // Typing between the taps.
        _ = model.handle(.pttFlagDown); _ = model.handle(.pttFlagUp)
        XCTAssertEqual(model.handle(.otherKeyDown), [.cancelTimer])
        XCTAssertEqual(model.phase, .idle)

        // Chord during the dwell.
        _ = model.handle(.pttFlagDown); _ = model.handle(.pttFlagUp); _ = model.handle(.pttFlagDown)
        XCTAssertEqual(model.handle(.otherKeyDown), [.cancelTimer])
        XCTAssertEqual(model.phase, .inert)
        _ = model.handle(.pttFlagUp)
        XCTAssertEqual(model.phase, .idle)
    }

    func testRepeatedChordsStayInertForever() {
        for _ in 0..<5 {
            _ = model.handle(.pttFlagDown)
            _ = model.handle(.otherKeyDown)
            _ = model.handle(.pttFlagUp)
        }
        XCTAssertEqual(model.phase, .idle)
    }

    func testKeysWhileGenuinelyTalkingDoNotCancel() {
        _ = model.handle(.pttFlagDown); _ = model.handle(.pttFlagUp)
        _ = model.handle(.pttFlagDown); _ = model.handle(.timerFired)
        XCTAssertEqual(model.phase, .held)
        XCTAssertEqual(model.handle(.otherKeyDown), [], "the chord rule exists only pre-capture")
        XCTAssertEqual(model.phase, .held)
        XCTAssertEqual(model.handle(.pttFlagUp), [.firePTTUp])
    }

    func testExactlyOneTimerPendingPerPhase() {
        // Every schedule is preceded (same batch or earlier) by the previous timer's cancellation,
        // so the driver's single one-shot slot is always unambiguous.
        var actions = model.handle(.pttFlagDown)
        XCTAssertEqual(actions.filter { if case .schedule = $0 { return true }; return false }.count, 1)
        actions = model.handle(.pttFlagUp)
        XCTAssertEqual(actions, [.cancelTimer, .schedule(.gap)])
        actions = model.handle(.pttFlagDown)
        XCTAssertEqual(actions, [.cancelTimer, .schedule(.dwell)])
    }
}
