import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for the Keep Awake automation's stateful lifecycle (spec: `automations`) against a recording
/// fake `Effects` — NO real displays/power. Proves: start dims every display + begins the assertion; the
/// triggering gesture can't self-cancel (arms only after the trackpad empties); the return-touch stops
/// it and restores the exact captured brightness + ends the assertion once; stop is idempotent; the
/// heartbeat re-pins brightness + re-declares user activity; an unreadable display is skipped.
@MainActor
final class KeepAwakeControllerTests: XCTestCase {

    // MARK: - Recording fake

    /// Records every effect the controller performs, and models a mutable "current brightness" per
    /// display so restore/heartbeat can be asserted against real state transitions.
    private final class Recorder {
        var displays: [CGDirectDisplayID] = [1, 2]
        var current: [CGDirectDisplayID: Float] = [1: 0.8, 2: 0.5]
        var unreadable: Set<CGDirectDisplayID> = []
        var setLog: [(CGDirectDisplayID, Float)] = []
        var beginCount = 0
        var endCount = 0
        var declareCount = 0
    }

    private func makeEffects(_ r: Recorder) -> KeepAwakeController.Effects {
        KeepAwakeController.Effects(
            activeDisplays: { r.displays },
            getBrightness: { r.unreadable.contains($0) ? nil : r.current[$0] },
            setBrightness: { id, v in r.setLog.append((id, v)); r.current[id] = v },
            beginActivity: { r.beginCount += 1; return NSObject() },
            endActivity: { _ in r.endCount += 1 },
            declareUserActive: { r.declareCount += 1 })
    }

    private func makeController(_ r: Recorder) -> KeepAwakeController {
        // A huge interval so the real timer never fires during the test; heartbeat is driven directly.
        KeepAwakeController(effects: makeEffects(r), heartbeatInterval: 1_000_000)
    }

    // MARK: - Start

    func testStartDimsAllReadableDisplaysAndBeginsActivity() {
        let r = Recorder()
        let c = makeController(r)
        c.start()

        XCTAssertTrue(c.isActive)
        XCTAssertEqual(r.beginCount, 1, "holds exactly one activity assertion")
        // Both displays set to the dim level.
        XCTAssertEqual(r.current[1], KeepAwakeController.dimLevel)
        XCTAssertEqual(r.current[2], KeepAwakeController.dimLevel)
        XCTAssertEqual(r.setLog.count, 2, "one set per readable display, no extras")
        c.stop()
    }

    func testUnreadableDisplayIsSkippedNeverFails() {
        let r = Recorder()
        r.unreadable = [2]                    // display 2 can't report brightness (e.g. external/DDC)
        let c = makeController(r)
        c.start()

        XCTAssertTrue(c.isActive, "still starts")
        XCTAssertEqual(r.current[1], KeepAwakeController.dimLevel, "readable display dimmed")
        XCTAssertEqual(r.current[2], 0.5, "unreadable display untouched")
        XCTAssertEqual(r.setLog.count, 1)

        c.stop()
        XCTAssertEqual(r.current[2], 0.5, "unreadable display never restored (never dimmed)")
    }

    // MARK: - Arming (first-touch-to-stop, self-cancel immune)

    func testTriggeringGestureCannotSelfCancel() {
        let r = Recorder()
        let c = makeController(r)
        c.start()

        // Residual contacts from the firing gesture arrive BEFORE the trackpad ever empties.
        c.noteTouch(fingerCount: 3)
        c.noteTouch(fingerCount: 2)
        c.noteTouch(fingerCount: 1)
        XCTAssertTrue(c.isActive, "not armed yet — the trigger can't self-cancel")

        c.stop()
    }

    func testArmsAfterEmptyThenNextTouchStopsAndRestores() {
        let r = Recorder()
        let c = makeController(r)
        c.start()
        XCTAssertEqual(r.current[1], KeepAwakeController.dimLevel)

        c.noteTouch(fingerCount: 0)          // trackpad empties → ARM
        XCTAssertTrue(c.isActive, "arming does not stop")

        c.noteTouch(fingerCount: 2)          // return touch → STOP
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.current[1], 0.8, "brightness restored to the captured value")
        XCTAssertEqual(r.current[2], 0.5)
        XCTAssertEqual(r.endCount, 1, "assertion released exactly once")
    }

    func testNoteTouchIsInertWhenInactive() {
        let r = Recorder()
        let c = makeController(r)
        c.noteTouch(fingerCount: 0)
        c.noteTouch(fingerCount: 3)
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.beginCount, 0)
    }

    // MARK: - Toggle + idempotent teardown

    func testToggleStartsThenStops() {
        let r = Recorder()
        let c = makeController(r)
        c.toggle()
        XCTAssertTrue(c.isActive)
        c.toggle()
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.beginCount, 1)
        XCTAssertEqual(r.endCount, 1)
    }

    func testIdempotentStop() {
        let r = Recorder()
        let c = makeController(r)
        c.start()
        c.stop()
        let setsAfterFirstStop = r.setLog.count
        c.stop()                             // second stop is a no-op
        c.stop()
        XCTAssertEqual(r.endCount, 1, "assertion ended only once")
        XCTAssertEqual(r.setLog.count, setsAfterFirstStop, "no double-restore")
    }

    func testStopWhenNeverStartedIsHarmless() {
        let r = Recorder()
        let c = makeController(r)
        c.stop()
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.endCount, 0)
        XCTAssertTrue(r.setLog.isEmpty)
    }

    // MARK: - Heartbeat

    func testHeartbeatRepinsBrightnessAndDeclaresActivity() {
        let r = Recorder()
        let c = makeController(r)
        c.start()
        // Something else raises brightness while active.
        r.current[1] = 0.9
        r.current[2] = 0.7

        c.heartbeatTick()

        XCTAssertEqual(r.current[1], KeepAwakeController.dimLevel, "re-pinned to minimum")
        XCTAssertEqual(r.current[2], KeepAwakeController.dimLevel)
        XCTAssertEqual(r.declareCount, 1, "re-declared user activity")
        c.stop()
    }

    func testHeartbeatIsInertWhenInactive() {
        let r = Recorder()
        let c = makeController(r)
        c.heartbeatTick()
        XCTAssertEqual(r.declareCount, 0)
        XCTAssertTrue(r.setLog.isEmpty)
    }

    // MARK: - onActiveChanged

    func testOnActiveChangedFiresOnStartAndStop() {
        let r = Recorder()
        let c = makeController(r)
        var flips: [Bool] = []
        c.onActiveChanged = { flips.append(c.isActive) }
        c.start()
        c.stop()
        XCTAssertEqual(flips, [true, false])
    }
}
