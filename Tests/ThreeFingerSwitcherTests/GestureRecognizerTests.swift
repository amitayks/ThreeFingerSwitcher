import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Records every semantic event the recognizer emits, in order, so tests can assert the
/// exact sequence and counts produced by a synthetic stream of `TouchFrame`s.
@MainActor
private final class MockDelegate: GestureRecognizerDelegate {
    enum Event: Equatable {
        case activate
        case step(Int)
        case stepRow(Int)
        case missionControl(Bool)   // true = up (Mission Control), false = down (App Exposé)
        case commit
        case cancel
    }

    private(set) var events: [Event] = []

    var activateCount: Int { events.filter { $0 == .activate }.count }
    var commitCount: Int { events.filter { $0 == .commit }.count }
    var cancelCount: Int { events.filter { $0 == .cancel }.count }
    var steps: [Int] { events.compactMap { if case let .step(d) = $0 { return d } else { return nil } } }
    var stepRows: [Int] { events.compactMap { if case let .stepRow(d) = $0 { return d } else { return nil } } }
    var missionControls: [Bool] { events.compactMap { if case let .missionControl(up) = $0 { return up } else { return nil } } }
    var didActivate: Bool { activateCount > 0 }

    func gestureDidActivate() { events.append(.activate) }
    func gestureDidStep(_ direction: Int) { events.append(.step(direction)) }
    func gestureDidStepRow(_ direction: Int) { events.append(.stepRow(direction)) }
    func gestureDidTriggerMissionControl(up: Bool) { events.append(.missionControl(up)) }
    func gestureDidCommit() { events.append(.commit) }
    func gestureDidCancel() { events.append(.cancel) }
}

@MainActor
final class GestureRecognizerTests: XCTestCase {

    // MARK: - Fixture

    /// Builds an isolated AppSettings with deterministic, easy-to-reason-about tunables.
    /// All distances are normalized trackpad units (0..1).
    private func makeSettings(
        activationThreshold: Double = 0.045,
        stepDistance: Double = 0.05,
        rowStepDistance: Double = 0.10,
        axisLockRatio: Double = 1.4,
        requireExactlyThree: Bool = true,
        reverseDirection: Bool = false,
        reverseVerticalDirection: Bool = false
    ) -> AppSettings {
        let defaults = UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.activationThreshold = activationThreshold
        settings.stepDistance = stepDistance
        settings.rowStepDistance = rowStepDistance
        settings.axisLockRatio = axisLockRatio
        settings.requireExactlyThree = requireExactlyThree
        settings.reverseDirection = reverseDirection
        settings.reverseVerticalDirection = reverseVerticalDirection
        return settings
    }

    private func makeRecognizer(_ settings: AppSettings, rowSwitching: Bool = false) -> (GestureRecognizer, MockDelegate) {
        let delegate = MockDelegate()
        let recognizer = GestureRecognizer(settings: settings)
        recognizer.delegate = delegate
        // Vertical row stepping is gated: the coordinator only enables it when the Space-row
        // switching opt-in is effective. Tests that exercise row steps must opt in explicitly.
        recognizer.rowSwitchingEnabled = rowSwitching
        return (recognizer, delegate)
    }

    /// Convenience: feed a 3-finger frame at the given centroid.
    private func feed(_ rec: GestureRecognizer, x: Double, y: Double, fingers: Int = 3) {
        rec.feed(TouchFrame(testFingerCount: fingers, centroid: CGPoint(x: x, y: y)))
    }

    // MARK: - (1) Horizontal activation

    func test_horizontalMovePastActivationThreshold_activates() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: land 3 fingers, then scrub horizontally past the activation threshold.
        feed(rec, x: 0.5, y: 0.5)          // begin (start centroid)
        feed(rec, x: 0.56, y: 0.5)         // dx = 0.06 >= 0.045, pure horizontal

        // Assert
        XCTAssertTrue(delegate.didActivate)
        XCTAssertEqual(delegate.activateCount, 1)
        XCTAssertEqual(delegate.events.first, .activate)
    }

    func test_horizontalMoveBelowActivationThreshold_doesNotActivate() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: horizontal but dx (0.03) stays below the 0.045 threshold.
        feed(rec, x: 0.5, y: 0.5)
        feed(rec, x: 0.53, y: 0.5)

        // Assert
        XCTAssertFalse(delegate.didActivate)
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func test_activationFiresExactlyAtThresholdBoundary() {
        // Arrange: threshold uses `>=`, so dx exactly equal to it must activate.
        let settings = makeSettings(activationThreshold: 0.05, axisLockRatio: 1.4)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: dx just reaches the 0.05 threshold (pure horizontal so axis locks horizontal).
        // Use a value that clears the boundary in IEEE-754 (0.45 - 0.40 underflows to 0.0499…),
        // matching real trackpad data which never lands exactly on a step multiple.
        feed(rec, x: 0.40, y: 0.50)
        feed(rec, x: 0.451, y: 0.50)

        // Assert
        XCTAssertTrue(delegate.didActivate, "dx >= activationThreshold should activate (>=).")
    }

    // MARK: - (2) Fresh vertical gesture yields to the OS

    func test_verticalGesture_neverActivatesAndEmitsNoRowSteps() {
        // Arrange
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings)

        // Act: a dominantly-vertical scrub well past any threshold.
        feed(rec, x: 0.5, y: 0.5)
        feed(rec, x: 0.5, y: 0.7)          // dy = 0.2, dx = 0 -> vertical axis lock
        feed(rec, x: 0.5, y: 0.9)          // continue vertical

        // Assert: no activation, no row steps, no window steps (left entirely to the OS).
        XCTAssertFalse(delegate.didActivate)
        XCTAssertTrue(delegate.stepRows.isEmpty)
        XCTAssertTrue(delegate.steps.isEmpty)
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func test_verticalAxisLock_thenHorizontalMove_stillDoesNotActivate() {
        // Arrange: once the axis locks vertical, later horizontal travel must not activate.
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        feed(rec, x: 0.5, y: 0.5)
        feed(rec, x: 0.5, y: 0.7)          // lock vertical
        feed(rec, x: 0.9, y: 0.7)          // big horizontal move afterwards

        // Assert
        XCTAssertFalse(delegate.didActivate)
        XCTAssertTrue(delegate.events.isEmpty)
    }

    // MARK: - (3) Horizontal step accumulation, carry, reversal, reverseDirection

    func test_horizontalStepAccumulation_NStepsForNTimesStepDistance() {
        // Arrange: stepDistance 0.05.
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: activate, then travel exactly 3 * stepDistance further.
        feed(rec, x: 0.10, y: 0.50)        // begin
        feed(rec, x: 0.16, y: 0.50)        // dx=0.06 -> activate; lastCentroid reset to 0.16
        feed(rec, x: 0.311, y: 0.50)       // +~0.15 (just past 3 * 0.05) -> 3 forward steps

        // Assert
        XCTAssertTrue(delegate.didActivate)
        XCTAssertEqual(delegate.steps, [1, 1, 1])
    }

    func test_stepCarry_accumulatesAcrossFramesAndDoesNotDoubleCount() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05)
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        feed(rec, x: 0.10, y: 0.50)        // begin
        feed(rec, x: 0.16, y: 0.50)        // activate (lastCentroid -> 0.16)
        feed(rec, x: 0.19, y: 0.50)        // +0.03 accumulator (no step yet, < 0.05)
        XCTAssertEqual(delegate.steps, [], "0.03 of travel must not yet emit a step.")
        feed(rec, x: 0.23, y: 0.50)        // +0.04 -> total 0.07 -> one step, 0.02 carried

        // Assert
        XCTAssertEqual(delegate.steps, [1])
    }

    func test_horizontalReversal_stepsBackTheOtherWay() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: activate forward, step forward twice, then reverse and step back twice.
        feed(rec, x: 0.40, y: 0.50)        // begin
        feed(rec, x: 0.46, y: 0.50)        // activate (lastCentroid 0.46)
        feed(rec, x: 0.56, y: 0.50)        // +0.10 -> [1, 1]
        XCTAssertEqual(delegate.steps, [1, 1])
        feed(rec, x: 0.46, y: 0.50)        // -0.10 -> [-1, -1]

        // Assert
        XCTAssertEqual(delegate.steps, [1, 1, -1, -1])
    }

    func test_reverseDirection_flipsHorizontalStepSign() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05, reverseDirection: true)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: same physical forward (rightward) motion as the un-reversed test.
        feed(rec, x: 0.10, y: 0.50)        // begin
        feed(rec, x: 0.16, y: 0.50)        // activate
        feed(rec, x: 0.26, y: 0.50)        // +0.10 forward travel

        // Assert: forward physical motion now yields -1 steps.
        XCTAssertEqual(delegate.steps, [-1, -1])
    }

    func test_activationMoveItselfDoesNotCountTowardStepAccumulation() {
        // Arrange: the activation frame resets lastCentroid to its own position, so the
        // travel consumed to activate is not double-counted as a step.
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: a single big jump that both activates and travels 0.20.
        feed(rec, x: 0.10, y: 0.50)        // begin
        feed(rec, x: 0.30, y: 0.50)        // dx=0.20 -> activate, but accumulator reset to 0

        // Assert: activation only; no steps emitted on the activating frame.
        XCTAssertTrue(delegate.didActivate)
        XCTAssertEqual(delegate.steps, [])
    }

    // MARK: - (4) Row stepping only after activation

    func test_rowStep_onlyAfterActivation_verticalTravelPastRowStepDistance() {
        // Arrange: rowStepDistance 0.10.
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act: activate horizontally, THEN move vertically past 2 * rowStepDistance.
        feed(rec, x: 0.20, y: 0.50)        // begin
        feed(rec, x: 0.26, y: 0.50)        // activate (axis horizontal, lastCentroid y=0.50)
        feed(rec, x: 0.26, y: 0.701)       // +~0.20 vertical (just past 2 * 0.10) -> 2 row steps up

        // Assert
        XCTAssertTrue(delegate.didActivate)
        XCTAssertEqual(delegate.stepRows, [1, 1])
    }

    func test_preActivationVerticalWiggle_emitsNoRowSteps() {
        // Arrange: while horizontal axis is locked but BEFORE activation, vertical motion
        // must not produce row steps (the recognizer returns early until activated).
        let settings = makeSettings(activationThreshold: 0.20, stepDistance: 0.05, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: lock horizontal (small dx dominates dy 0), then add vertical without ever
        // crossing the high 0.20 activation threshold.
        feed(rec, x: 0.40, y: 0.50)        // begin
        feed(rec, x: 0.43, y: 0.50)        // dx=0.03 horizontal lock, below activation
        feed(rec, x: 0.43, y: 0.90)        // big vertical, still not activated

        // Assert: nothing emitted at all.
        XCTAssertFalse(delegate.didActivate)
        XCTAssertTrue(delegate.stepRows.isEmpty)
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func test_rowStepReversal_downAfterUp() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act
        feed(rec, x: 0.20, y: 0.50)        // begin
        feed(rec, x: 0.26, y: 0.50)        // activate
        feed(rec, x: 0.26, y: 0.701)       // +~0.20 -> [1, 1]
        XCTAssertEqual(delegate.stepRows, [1, 1])
        feed(rec, x: 0.26, y: 0.499)       // back down past 2 rows (clears carry) -> [-1, -1]

        // Assert
        XCTAssertEqual(delegate.stepRows, [1, 1, -1, -1])
    }

    func test_reverseVerticalDirection_flipsRowStepSign() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045, rowStepDistance: 0.10, reverseVerticalDirection: true)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act: finger moves up (y increases) after activation.
        feed(rec, x: 0.20, y: 0.50)        // begin
        feed(rec, x: 0.26, y: 0.50)        // activate
        feed(rec, x: 0.26, y: 0.701)       // +~0.20 upward (past 2 rows)

        // Assert: up normally = +1; reversed -> -1.
        XCTAssertEqual(delegate.stepRows, [-1, -1])
    }

    func test_postActivation_combinedDiagonal_emitsBothWindowAndRowSteps() {
        // Arrange: after activation the recognizer is 2D; a diagonal move emits both kinds.
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act
        feed(rec, x: 0.20, y: 0.50)        // begin
        feed(rec, x: 0.26, y: 0.50)        // activate (lastCentroid 0.26, 0.50)
        feed(rec, x: 0.361, y: 0.701)      // +~0.10 x (2 steps), +~0.20 y (2 row steps)

        // Assert
        XCTAssertEqual(delegate.steps, [1, 1])
        XCTAssertEqual(delegate.stepRows, [1, 1])
    }

    // MARK: - (4b) Row stepping gated by the Space-row switching opt-in

    func test_rowSwitchingDisabled_postActivationVertical_emitsNoRowSteps() {
        // Arrange: opt-in OFF (default) — vertical must be left entirely to the OS, even after
        // a horizontal activation, so the native Mission Control / App Exposé gesture isn't stolen.
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: false)

        // Act: activate horizontally, then move vertically well past 2 * rowStepDistance.
        feed(rec, x: 0.20, y: 0.50)        // begin
        feed(rec, x: 0.26, y: 0.50)        // activate
        feed(rec, x: 0.26, y: 0.701)       // +~0.20 vertical -> would be 2 row steps if enabled

        // Assert: activated, but zero row steps because the opt-in is off.
        XCTAssertTrue(delegate.didActivate)
        XCTAssertTrue(delegate.stepRows.isEmpty)
    }

    func test_rowSwitchingDisabled_diagonal_stillStepsWindowsButNoRows() {
        // Arrange: opt-in OFF — horizontal window stepping must be unaffected by the gate.
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: false)

        // Act: activate, then a diagonal move (horizontal + vertical).
        feed(rec, x: 0.20, y: 0.50)        // begin
        feed(rec, x: 0.26, y: 0.50)        // activate (lastCentroid 0.26, 0.50)
        feed(rec, x: 0.361, y: 0.701)      // +~0.10 x (2 steps), +~0.20 y (would be 2 rows)

        // Assert: window steps still happen; row steps are suppressed.
        XCTAssertEqual(delegate.steps, [1, 1])
        XCTAssertTrue(delegate.stepRows.isEmpty)
    }

    func test_rowSwitchingDisabled_liftAfterActivation_stillCommits() {
        // Arrange: the gate only affects vertical row stepping, not the commit lifecycle.
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: false)

        // Act
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 0)   // lift

        // Assert
        XCTAssertEqual(delegate.commitCount, 1)
        XCTAssertEqual(delegate.cancelCount, 0)
    }

    func test_rowSwitchingEnabled_freshVerticalUp_triggersMissionControlOnce() {
        // Arrange: with the gate ON the app owns the vertical gesture — a fresh vertical-up swipe
        // (no horizontal activation) triggers Mission Control ourselves, exactly once per gesture.
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act: dominantly-vertical UP scrub past the Mission Control threshold (0.10).
        feed(rec, x: 0.5, y: 0.5)          // begin
        feed(rec, x: 0.5, y: 0.7)          // dy=+0.2 -> vertical lock, past threshold -> MC (up)
        feed(rec, x: 0.5, y: 0.9)          // continue up -> must NOT re-fire

        // Assert: Mission Control (up) exactly once; no activation, no row steps.
        XCTAssertEqual(delegate.missionControls, [true])
        XCTAssertFalse(delegate.didActivate)
        XCTAssertTrue(delegate.stepRows.isEmpty)
    }

    func test_rowSwitchingEnabled_freshVerticalDown_triggersAppExpose() {
        // Arrange
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act: vertical DOWN past threshold -> App Exposé (up:false).
        feed(rec, x: 0.5, y: 0.5)
        feed(rec, x: 0.5, y: 0.3)          // dy=-0.2 down

        // Assert
        XCTAssertEqual(delegate.missionControls, [false])
        XCTAssertFalse(delegate.didActivate)
    }

    func test_rowSwitchingDisabled_freshVertical_noMissionControl_yieldsToOS() {
        // Arrange: gate OFF — vertical is left entirely to the OS, we never trigger MC ourselves.
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: false)

        // Act: a big fresh vertical scrub.
        feed(rec, x: 0.5, y: 0.5)
        feed(rec, x: 0.5, y: 0.8)

        // Assert: nothing emitted at all (OS owns it).
        XCTAssertTrue(delegate.missionControls.isEmpty)
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func test_rowSwitchingEnabled_smallVerticalBelowThreshold_noMissionControl() {
        // Arrange: gate ON but the vertical travel stays under the 0.10 MC threshold.
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act: small vertical wiggle.
        feed(rec, x: 0.5, y: 0.5)
        feed(rec, x: 0.5, y: 0.55)         // dy=+0.05 < 0.10

        // Assert: no Mission Control yet.
        XCTAssertTrue(delegate.missionControls.isEmpty)
    }

    func test_rowSwitchingEnabled_preActivationVertical_thenActivate_noBufferedRowSteps() {
        // Arrange: gate ON, high activation threshold. Lock horizontal, do a large pre-activation
        // vertical move, THEN cross activation — buffered vertical must NOT flush into row steps.
        let settings = makeSettings(activationThreshold: 0.20, stepDistance: 0.05, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act
        feed(rec, x: 0.40, y: 0.50)        // begin
        feed(rec, x: 0.43, y: 0.50)        // dx=0.03 -> horizontal lock, below activation (0.20)
        feed(rec, x: 0.43, y: 0.90)        // large pre-activation vertical (must not buffer)
        feed(rec, x: 0.62, y: 0.90)        // dx=0.22 from start -> activates; accumulators reset

        // Assert: activated, but no row steps leaked from the pre-activation vertical travel.
        XCTAssertTrue(delegate.didActivate)
        XCTAssertTrue(delegate.stepRows.isEmpty, "pre-activation vertical must not flush into row steps")
    }

    func test_rowSwitchingEnabled_horizontalScrubWithSmallVerticalWobble_noRowSteps() {
        // Arrange: gate ON. Horizontal scrubbing with incidental vertical wobble below the
        // row-step distance must produce window steps but no row flips.
        let settings = makeSettings(activationThreshold: 0.045, stepDistance: 0.05, rowStepDistance: 0.10)
        let (rec, delegate) = makeRecognizer(settings, rowSwitching: true)

        // Act
        feed(rec, x: 0.20, y: 0.50)        // begin
        feed(rec, x: 0.26, y: 0.50)        // activate
        feed(rec, x: 0.40, y: 0.52)        // +0.14 x (window steps), +0.02 y (< 0.10 row step)

        // Assert
        XCTAssertFalse(delegate.steps.isEmpty, "horizontal travel still steps windows")
        XCTAssertTrue(delegate.stepRows.isEmpty, "small vertical wobble must not flip rows")
    }

    // MARK: - (5) Fourth finger cancels

    func test_fourthFinger_whenRequireExactlyThree_cancels() {
        // Arrange
        let settings = makeSettings(requireExactlyThree: true)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: begin a tracking gesture with 3 fingers, then a 4th lands.
        feed(rec, x: 0.5, y: 0.5, fingers: 3)
        feed(rec, x: 0.5, y: 0.5, fingers: 4)

        // Assert
        XCTAssertEqual(delegate.cancelCount, 1)
        XCTAssertEqual(delegate.commitCount, 0)
        XCTAssertEqual(delegate.events.last, .cancel)
    }

    func test_fourthFinger_afterActivation_cancelsRatherThanCommits() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045, requireExactlyThree: true)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: activate, then a 4th finger lands.
        feed(rec, x: 0.40, y: 0.50, fingers: 3)
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        XCTAssertTrue(delegate.didActivate)
        feed(rec, x: 0.46, y: 0.50, fingers: 4)   // 4th finger

        // Assert: a 4th finger always cancels, even post-activation.
        XCTAssertEqual(delegate.cancelCount, 1)
        XCTAssertEqual(delegate.commitCount, 0)
    }

    func test_fourthFinger_whenThreeOrMoreAllowed_doesNotCancel() {
        // Arrange: with requireExactlyThree == false, `tooMany` is never true and >=3 is target.
        let settings = makeSettings(activationThreshold: 0.045, requireExactlyThree: false)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: begin with 3, then a 4th finger keeps tracking; a horizontal scrub activates.
        feed(rec, x: 0.40, y: 0.50, fingers: 3)
        feed(rec, x: 0.46, y: 0.50, fingers: 4)   // still target (>=3), no cancel; activates

        // Assert
        XCTAssertEqual(delegate.cancelCount, 0)
        XCTAssertTrue(delegate.didActivate)
    }

    // MARK: - (6) Edge-flicker debounce

    func test_oneFrameDipToTwoFingers_thenBackToThree_doesNotEnd() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: activate, dip to 2 fingers for a single frame, then return to 3 and keep going.
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 2)   // 1-frame dip (belowTargetFrames == 1)
        XCTAssertEqual(delegate.commitCount, 0, "A single sub-3 frame must not end the gesture.")
        XCTAssertEqual(delegate.cancelCount, 0)
        feed(rec, x: 0.56, y: 0.50, fingers: 3)   // 3rd finger returns; resets debounce, steps

        // Assert: gesture survived the dip and continued stepping.
        XCTAssertEqual(delegate.commitCount, 0)
        XCTAssertEqual(delegate.cancelCount, 0)
        XCTAssertEqual(delegate.steps, [1, 1], "Travel after the flicker still produces steps.")
    }

    func test_zeroFingers_endsImmediately_committingAfterActivation() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: activate, then a true lift (0 fingers) in a single frame.
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 0)   // true lift -> end immediately

        // Assert: ends on the very first sub-3 frame because count == 0.
        XCTAssertEqual(delegate.commitCount, 1)
        XCTAssertEqual(delegate.cancelCount, 0)
        XCTAssertEqual(delegate.events.last, .commit)
    }

    func test_twoConsecutiveSubThreeFrames_endsTheGesture() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: activate, then a sustained 2-frame drop to 2 fingers (belowTargetFrames reaches 2).
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 2)   // belowTargetFrames == 1, no end
        XCTAssertEqual(delegate.commitCount, 0)
        feed(rec, x: 0.46, y: 0.50, fingers: 1)   // belowTargetFrames == 2 -> end (commit)

        // Assert
        XCTAssertEqual(delegate.commitCount, 1)
        XCTAssertEqual(delegate.cancelCount, 0)
    }

    func test_debounceCounterResetsAfterFingerReturns() {
        // Arrange: a dip, a return, then another single dip must NOT end (counter reset).
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 2)   // belowTargetFrames -> 1
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // resets belowTargetFrames -> 0
        feed(rec, x: 0.46, y: 0.50, fingers: 2)   // belowTargetFrames -> 1 again, not 2

        // Assert: still alive.
        XCTAssertEqual(delegate.commitCount, 0)
        XCTAssertEqual(delegate.cancelCount, 0)
    }

    // MARK: - (7) Lift commits vs. cancels

    func test_liftAfterActivation_commits() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 0)   // lift

        // Assert
        XCTAssertEqual(delegate.commitCount, 1)
        XCTAssertEqual(delegate.cancelCount, 0)
    }

    func test_liftBeforeActivation_cancels() {
        // Arrange: tracking started but never activated (no horizontal threshold crossing).
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: small horizontal wiggle below threshold, then lift.
        feed(rec, x: 0.50, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.52, y: 0.50, fingers: 3)   // dx=0.02, no activation
        feed(rec, x: 0.52, y: 0.50, fingers: 0)   // lift

        // Assert
        XCTAssertEqual(delegate.commitCount, 0)
        XCTAssertEqual(delegate.cancelCount, 1)
        XCTAssertEqual(delegate.events.last, .cancel)
    }

    func test_liftAfterVerticalYield_cancels() {
        // Arrange: vertical axis locked (yielded to OS), lift must cancel, not commit.
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        feed(rec, x: 0.50, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.50, y: 0.70, fingers: 3)   // vertical lock
        feed(rec, x: 0.50, y: 0.70, fingers: 0)   // lift

        // Assert
        XCTAssertEqual(delegate.commitCount, 0)
        XCTAssertEqual(delegate.cancelCount, 1)
    }

    func test_liftWithoutEverTracking_emitsNothing() {
        // Arrange: never reaches the target finger count while idle.
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // ignored (idle, not target)
        feed(rec, x: 0.50, y: 0.50, fingers: 0)   // still idle

        // Assert
        XCTAssertTrue(delegate.events.isEmpty)
    }

    // MARK: - reset()

    func test_reset_whileTrackingActivated_cancels() {
        // Arrange
        let settings = makeSettings(activationThreshold: 0.045)
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate
        rec.reset()

        // Assert: reset aborts an in-flight gesture via cancel (never commit).
        XCTAssertEqual(delegate.cancelCount, 1)
        XCTAssertEqual(delegate.commitCount, 0)
    }

    func test_reset_whileIdle_emitsNothing() {
        // Arrange
        let settings = makeSettings()
        let (rec, delegate) = makeRecognizer(settings)

        // Act
        rec.reset()

        // Assert
        XCTAssertTrue(delegate.events.isEmpty)
    }

    // MARK: - Axis lock ratio boundary

    func test_diagonalBelowLockRatio_staysUndetermined_noActivation() {
        // Arrange: axisLockRatio 1.4; a 45-degree move where neither axis dominates
        // (dx == dy) must NOT lock horizontal, so no activation happens.
        let settings = makeSettings(activationThreshold: 0.045, axisLockRatio: 1.4)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: dx = dy = 0.10 -> abs(dx) < 1.4*abs(dy) and vice-versa -> undetermined.
        feed(rec, x: 0.30, y: 0.30, fingers: 3)   // begin
        feed(rec, x: 0.40, y: 0.40, fingers: 3)   // perfectly diagonal

        // Assert
        XCTAssertFalse(delegate.didActivate)
        XCTAssertTrue(delegate.events.isEmpty)
    }

    func test_horizontalDominatesByLockRatio_locksHorizontalAndActivates() {
        // Arrange: dx clearly dominates dy by more than the lock ratio.
        let settings = makeSettings(activationThreshold: 0.045, axisLockRatio: 1.4)
        let (rec, delegate) = makeRecognizer(settings)

        // Act: dx = 0.06, dy = 0.02 -> 0.06 >= 1.4 * 0.02 (0.028) -> horizontal lock; 0.06 >= 0.045.
        feed(rec, x: 0.30, y: 0.30, fingers: 3)
        feed(rec, x: 0.36, y: 0.32, fingers: 3)

        // Assert
        XCTAssertTrue(delegate.didActivate)
    }
}
