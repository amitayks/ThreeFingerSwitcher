import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for the Keep Awake automation's stateful lifecycle (spec: `automations`) against a recording
/// fake `Effects` — NO real displays/power/monitors. Proves: start dims every display + begins the
/// assertion; the triggering gesture can't self-cancel (arms only after the trackpad empties); the
/// return-touch stops it and restores the exact captured brightness + ends the assertion once; stop is
/// idempotent; the heartbeat re-pins brightness + re-declares user activity; an unreadable display is
/// skipped. The `keep-awake-guard-effects` additions: the keyboard-backlight session effect (snapshot →
/// zero → re-pin → restore, skip-unreadable, off-by-default) and the guard (monitor installed only at
/// ARM, any input stops + locks BEFORE restore, explicit stops never lock).
@MainActor
final class KeepAwakeControllerTests: XCTestCase {

    // MARK: - Recording fake

    /// Records every effect the controller performs, and models a mutable "current brightness" per
    /// display (and keyboard) so restore/heartbeat can be asserted against real state transitions.
    /// `sequence` interleaves ordered effect names so stop ordering (monitor→lock→restore) is provable.
    private final class Recorder {
        var displays: [CGDirectDisplayID] = [1, 2]
        var current: [CGDirectDisplayID: Float] = [1: 0.8, 2: 0.5]
        var unreadable: Set<CGDirectDisplayID> = []
        var setLog: [(CGDirectDisplayID, Float)] = []
        var beginCount = 0
        var endCount = 0
        var declareCount = 0
        var keyboards: [UInt64] = [10]
        var kbCurrent: [UInt64: Float] = [10: 0.6]
        var kbUnreadable: Set<UInt64> = []
        var kbSetLog: [(UInt64, Float)] = []
        var lockCount = 0
        var monitorBeginCount = 0
        var monitorEndCount = 0
        /// The guard callback captured at install — a test fires it to simulate mouse/key input.
        var monitorInput: (() -> Void)?
        var sequence: [String] = []
    }

    private func makeEffects(_ r: Recorder) -> KeepAwakeController.Effects {
        KeepAwakeController.Effects(
            activeDisplays: { r.displays },
            getBrightness: { r.unreadable.contains($0) ? nil : r.current[$0] },
            setBrightness: { id, v in
                r.setLog.append((id, v)); r.current[id] = v; r.sequence.append("display(\(id))")
            },
            beginActivity: { r.beginCount += 1; return NSObject() },
            endActivity: { _ in r.endCount += 1; r.sequence.append("endActivity") },
            declareUserActive: { r.declareCount += 1 },
            keyboardBacklightIDs: { r.keyboards },
            getKeyboardBrightness: { r.kbUnreadable.contains($0) ? nil : r.kbCurrent[$0] },
            setKeyboardBrightness: { id, v in
                r.kbSetLog.append((id, v)); r.kbCurrent[id] = v; r.sequence.append("keyboard(\(id))")
            },
            lockScreen: { r.lockCount += 1; r.sequence.append("lock") },
            beginInputMonitoring: { onInput in
                r.monitorBeginCount += 1; r.monitorInput = onInput; return NSObject()
            },
            endInputMonitoring: { _ in
                r.monitorEndCount += 1; r.monitorInput = nil; r.sequence.append("endMonitor")
            })
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

    // MARK: - Configurable dim level

    func testStartDimsToConfiguredLevelAndHeartbeatRepinsThere() {
        let r = Recorder()
        let c = makeController(r)
        c.start(dimTo: 0.1)                    // 10%, not minimum
        XCTAssertEqual(r.current[1], 0.1)
        XCTAssertEqual(r.current[2], 0.1)

        r.current[1] = 0.9                      // something raises it
        c.heartbeatTick()
        XCTAssertEqual(r.current[1], 0.1, "heartbeat re-pins to the configured level, not 0")

        c.stop()
        XCTAssertEqual(r.current[1], 0.8, "restore is independent of the dim level")
        XCTAssertEqual(r.current[2], 0.5)
    }

    func testFractionFromPercentClampsAndDefaultsToMinimum() {
        XCTAssertEqual(KeepAwakeController.fraction(fromPercent: nil), 0)
        XCTAssertEqual(KeepAwakeController.fraction(fromPercent: 0), 0)
        XCTAssertEqual(KeepAwakeController.fraction(fromPercent: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(KeepAwakeController.fraction(fromPercent: 100), 1)
        XCTAssertEqual(KeepAwakeController.fraction(fromPercent: 150), 1, "clamped high")
        XCTAssertEqual(KeepAwakeController.fraction(fromPercent: -10), 0, "clamped low")
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

    // MARK: - Keyboard backlight session effect (keep-awake-guard-effects)

    func testKeyboardDimsOnStartAndRestoresOnStop() {
        let r = Recorder()
        let c = makeController(r)
        c.start(KeepAwakeController.Config(dimKeyboard: true))

        XCTAssertEqual(r.kbCurrent[10], 0, "backlight zeroed on start")

        c.stop()
        XCTAssertEqual(r.kbCurrent[10], 0.6, "backlight restored to the captured level")
    }

    func testKeyboardOptionOffLeavesKeyboardUntouched() {
        let r = Recorder()
        let c = makeController(r)
        c.start()                              // default config: dimKeyboard = false
        c.noteTouch(fingerCount: 0)
        c.noteTouch(fingerCount: 1)            // input stop
        XCTAssertTrue(r.kbSetLog.isEmpty, "keyboard never read or written when the option is off")
        XCTAssertEqual(r.kbCurrent[10], 0.6)
    }

    func testUnreadableKeyboardIsSkippedNeverFails() {
        let r = Recorder()
        r.kbUnreadable = [10]
        let c = makeController(r)
        c.start(KeepAwakeController.Config(dimKeyboard: true))

        XCTAssertTrue(c.isActive, "still starts")
        XCTAssertTrue(r.kbSetLog.isEmpty, "unreadable keyboard untouched")

        c.stop()
        XCTAssertEqual(r.kbCurrent[10], 0.6, "never restored (never dimmed)")
    }

    func testHeartbeatRepinsKeyboardToZero() {
        let r = Recorder()
        let c = makeController(r)
        c.start(KeepAwakeController.Config(dimKeyboard: true))
        r.kbCurrent[10] = 0.4                  // auto-illumination raises it

        c.heartbeatTick()

        XCTAssertEqual(r.kbCurrent[10], 0, "re-pinned to zero")
        c.stop()
        XCTAssertEqual(r.kbCurrent[10], 0.6, "restore unaffected by re-pins")
    }

    // MARK: - Guard: any-input stop + lock (keep-awake-guard-effects)

    private func startGuarded(_ r: Recorder) -> KeepAwakeController {
        let c = makeController(r)
        c.start(KeepAwakeController.Config(dimKeyboard: true, lockOnStop: true))
        return c
    }

    func testGuardInstallsMonitorOnlyAtArm() {
        let r = Recorder()
        let c = startGuarded(r)
        XCTAssertEqual(r.monitorBeginCount, 0, "no monitor before the trigger lifts")

        c.noteTouch(fingerCount: 2)            // residual trigger contacts
        XCTAssertEqual(r.monitorBeginCount, 0)

        c.noteTouch(fingerCount: 0)            // trackpad empties → ARM
        XCTAssertEqual(r.monitorBeginCount, 1, "monitor installed exactly at ARM")
        XCTAssertEqual(r.lockCount, 0)
        c.stop()
    }

    func testGuardOffInstallsNoMonitorAndNeverLocks() {
        let r = Recorder()
        let c = makeController(r)
        c.start()                              // lockOnStop = false
        c.noteTouch(fingerCount: 0)
        XCTAssertEqual(r.monitorBeginCount, 0, "no monitor without the guard option")

        c.noteTouch(fingerCount: 1)            // touch stop
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.lockCount, 0, "base behavior: stop without lock")
    }

    func testGuardMonitorInputStopsAndLocksBeforeRestore() {
        let r = Recorder()
        let c = startGuarded(r)
        c.noteTouch(fingerCount: 0)            // ARM (installs monitor)
        r.sequence.removeAll()

        r.monitorInput?()                       // simulated mouse move / key press

        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.lockCount, 1, "locked exactly once")
        XCTAssertEqual(r.monitorEndCount, 1, "monitor removed")
        XCTAssertEqual(r.current[1], 0.8, "brightness restored behind the lock")
        XCTAssertEqual(r.kbCurrent[10], 0.6, "backlight restored behind the lock")
        // Ordering: monitor off → lock → keyboard restore → display restore → assertion end.
        let order = ["endMonitor", "lock", "keyboard(10)"]
        let indices = order.compactMap { r.sequence.firstIndex(of: $0) }
        XCTAssertEqual(indices.count, order.count, "all stop effects ran: \(r.sequence)")
        XCTAssertEqual(indices, indices.sorted(), "lock precedes every restore: \(r.sequence)")
        if let lock = r.sequence.firstIndex(of: "lock"),
           let display = r.sequence.firstIndex(of: "display(1)") {
            XCTAssertLessThan(lock, display, "no unlocked-desktop flash")
        } else {
            XCTFail("missing lock/display entries in \(r.sequence)")
        }
    }

    func testGuardTouchStopAlsoLocks() {
        let r = Recorder()
        let c = startGuarded(r)
        c.noteTouch(fingerCount: 0)            // ARM
        c.noteTouch(fingerCount: 1)            // a finger lands — input-path stop

        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.lockCount, 1, "trackpad input locks too")
        XCTAssertEqual(r.monitorEndCount, 1)
    }

    func testGuardExplicitStopNeverLocksButRemovesMonitor() {
        let r = Recorder()
        let c = startGuarded(r)
        c.noteTouch(fingerCount: 0)            // ARM (monitor live)

        c.stop()                               // menu bar / quit / will-sleep / re-fire toggle

        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.lockCount, 0, "explicit and teardown stops never lock")
        XCTAssertEqual(r.monitorEndCount, 1, "monitor still torn down")
        XCTAssertEqual(r.current[1], 0.8)
        XCTAssertEqual(r.kbCurrent[10], 0.6)
    }

    func testGuardDoubleStopEndsMonitorAndLockOnce() {
        let r = Recorder()
        let c = startGuarded(r)
        c.noteTouch(fingerCount: 0)
        r.monitorInput?()
        c.stop(reason: .input)                 // stray second stop
        c.stop()
        XCTAssertEqual(r.lockCount, 1)
        XCTAssertEqual(r.monitorEndCount, 1)
        XCTAssertEqual(r.endCount, 1)
    }

    func testGuardedToggleOffIsExplicitNoLock() {
        let r = Recorder()
        let c = makeController(r)
        let config = KeepAwakeController.Config(lockOnStop: true)
        c.toggle(config)
        XCTAssertTrue(c.isActive)
        c.toggle(config)                       // re-fire while active
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.lockCount, 0, "a re-fire toggle is an explicit stop")
    }
}
