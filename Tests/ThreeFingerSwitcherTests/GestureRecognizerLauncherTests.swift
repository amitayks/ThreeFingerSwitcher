import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Records both switcher and launcher intents so tests can assert the recognizer routes a latched
/// four-finger gesture to the launcher while leaving three-finger behavior untouched.
@MainActor
private final class LauncherMockDelegate: GestureRecognizerDelegate {
    enum Event: Equatable {
        case activate, step(Int), stepRow(Int), missionControl(Bool), commit, cancel
        case lActivate, lItem(Int), lContext(Int), lEnd, lCancel
        case lEdge(Int, Int)
        case lCanvasResolve(Int, Int)
    }
    private(set) var events: [Event] = []
    /// Simulates the launcher cursor sitting on the band-title list (left), so **vertical** travel is
    /// treated as band switching (the coarse context-step) rather than in-grid row movement (the fine
    /// item-step). Horizontal travel is always the fine item-step.
    var onBandList = false

    // Switcher
    func gestureDidActivate() { events.append(.activate) }
    func gestureDidStep(_ d: Int) { events.append(.step(d)) }
    func gestureDidStepRow(_ d: Int) { events.append(.stepRow(d)) }
    func gestureDidTriggerMissionControl(up: Bool) { events.append(.missionControl(up)) }
    func gestureDidCommit() { events.append(.commit) }
    func gestureDidCancel() { events.append(.cancel) }

    // Launcher
    func launcherDidActivate() { events.append(.lActivate) }
    func launcherDidStepItem(_ d: Int) { events.append(.lItem(d)) }
    func launcherDidStepContext(_ d: Int) { events.append(.lContext(d)) }
    func launcherDidEnd() { events.append(.lEnd) }
    func launcherDidCancel() { events.append(.lCancel) }
    func launcherEdgeChanged(dx: Int, dy: Int) { events.append(.lEdge(dx, dy)) }
    func launcherFocusIsOnBandList() -> Bool { onBandList }
    func launcherCanvasResolve(dx: Int, dy: Int) { events.append(.lCanvasResolve(dx, dy)) }

    /// The sequence of edge states emitted (dx, dy) per change.
    var edges: [(Int, Int)] { events.compactMap { if case let .lEdge(x, y) = $0 { return (x, y) } else { return nil } } }
    var lastEdge: (Int, Int)? { edges.last }

    var lActivateCount: Int { events.filter { $0 == .lActivate }.count }
    var lEndCount: Int { events.filter { $0 == .lEnd }.count }
    var lCancelCount: Int { events.filter { $0 == .lCancel }.count }
    var lItems: [Int] { events.compactMap { if case let .lItem(d) = $0 { return d } else { return nil } } }
    var lContexts: [Int] { events.compactMap { if case let .lContext(d) = $0 { return d } else { return nil } } }
    /// The (dx, dy) of each canvas-resolution emitted (horizontal swipe = discard; dy −1 down = apply).
    var canvasResolves: [(Int, Int)] {
        events.compactMap { if case let .lCanvasResolve(x, y) = $0 { return (x, y) } else { return nil } }
    }
    var commitCount: Int { events.filter { $0 == .commit }.count }
    var cancelCount: Int { events.filter { $0 == .cancel }.count }
    var didSwitcherActivate: Bool { events.contains(.activate) }
}

@MainActor
final class GestureRecognizerLauncherTests: XCTestCase {

    // Positional navigation (change `positional-navigation`): the launcher is now **position-tracking**
    // inside a **padding box** — the selection index follows the finger's offset (`round(offset/step)`,
    // both directions, center locked) until the offset leaves the box (`|offset| ≥ paddingRadius`) or the
    // centroid enters the fixed **edge-margin band**, where it accelerates (held sign). Test frames carry
    // no footprint, so the offset uses `positionalFallbackScale` — with fallbackScale 0.1, offset =
    // travel / 0.1. With itemStep 0.5 → one item step per 0.05 of travel; paddingRadius 2.0 → the box edge
    // is at 0.20 of travel; bandStep 1.0 → one band step per 0.10 of travel.
    private func makeSettings(
        launcherActivationThreshold: Double = 0.045,
        itemStep: Double = 0.5,
        bandStep: Double = 1.0,
        paddingRadius: Double = 2.0,
        edgeMargin: Double = 0.10,
        fallbackScale: Double = 0.1,
        reArmBackoff: Double = 0.0,
        requireExactlyThree: Bool = true
    ) -> AppSettings {
        let defaults = UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.launcherActivationThreshold = launcherActivationThreshold
        settings.launcherStepDistance = itemStep              // item position-step (offset per step)
        settings.launcherContextStepDistance = bandStep       // band position-step (coarser)
        settings.positionalPaddingRadius = paddingRadius      // box half-size → margin beyond it
        settings.positionalEdgeMargin = edgeMargin            // fixed border band (accelerate)
        settings.positionalFallbackScale = fallbackScale      // no footprint in test frames → fallback
        settings.positionalReArmBackoff = reArmBackoff        // off by default so stepping tests are clean
        settings.activationThreshold = 0.045
        settings.stepDistance = 0.05
        settings.requireExactlyThree = requireExactlyThree
        return settings
    }

    private func makeRecognizer(_ settings: AppSettings, launcher: Bool) -> (GestureRecognizer, LauncherMockDelegate) {
        let delegate = LauncherMockDelegate()
        let rec = GestureRecognizer(settings: settings)
        rec.delegate = delegate
        rec.launcherEnabled = launcher
        return (rec, delegate)
    }

    private func feed(_ rec: GestureRecognizer, x: Double, y: Double, fingers: Int) {
        rec.feed(TouchFrame(testFingerCount: fingers, centroid: CGPoint(x: x, y: y)))
    }

    // MARK: - Latching: four fingers → launcher

    func test_fourFingerHorizontal_activatesLauncher() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin launcher
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // dx 0.06 >= 0.045 → activate
        XCTAssertEqual(d.lActivateCount, 1)
        XCTAssertEqual(d.events.first, .lActivate)
        XCTAssertFalse(d.didSwitcherActivate)
    }

    func test_fourFingerBelowThreshold_doesNotActivate() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.52, y: 0.50, fingers: 4)   // dx 0.02 < 0.045
        XCTAssertEqual(d.lActivateCount, 0)
        XCTAssertTrue(d.events.isEmpty)
    }

    func test_itemStepping_positionTracksFinger() {
        // Position-tracking: the selection FOLLOWS the finger's offset in steps. Pushing to offset +1.5
        // (3 item-steps) emits 3 steps at once; holding there emits no more (index already matches).
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.10, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.16, y: 0.50, fingers: 4)   // activate → anchor (0.16, 0.50)
        feed(rec, x: 0.31, y: 0.50, fingers: 4)   // offset x +1.5 → index 3 → +3 steps
        XCTAssertEqual(d.lItems, [1, 1, 1], "the cursor tracks the finger's position in the box")
        feed(rec, x: 0.31, y: 0.50, fingers: 4)   // unchanged position → no further steps
        XCTAssertEqual(d.lItems, [1, 1, 1])
    }

    func test_itemStepping_movingBackStepsBack() {
        // Moving back toward center steps the selection back (position-tracking is bidirectional).
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.10, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.16, y: 0.50, fingers: 4)   // activate → anchor (0.16, 0.50)
        feed(rec, x: 0.31, y: 0.50, fingers: 4)   // offset +1.5 → index 3 → +3
        feed(rec, x: 0.16, y: 0.50, fingers: 4)   // back to center → index 0 → −3
        XCTAssertEqual(d.lItems, [1, 1, 1, -1, -1, -1])
    }

    func test_verticalStepping_inGrid_usesItemStep() {
        // In the grid (NOT the band list), vertical uses the fine item step: offset +0.6 → one row step.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.20, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.26, y: 0.50, fingers: 4)   // activate → anchor (0.26, 0.50)
        feed(rec, x: 0.26, y: 0.56, fingers: 4)   // dy offset +0.6 → round(0.6/0.5)=1 → one row step
        XCTAssertEqual(d.lContexts, [1], "grid rows step at the item step")
        XCTAssertTrue(d.lItems.isEmpty, "pure vertical emits no horizontal steps")
    }

    func test_bandSwitch_onBandList_usesCoarserBandStep_onVertical() {
        // On the band list, VERTICAL uses the coarser band step: an offset that would step a grid row
        // (0.4 → item index 1) does NOT switch a band yet (0.4 → band index 0); it needs more offset.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        d.onBandList = true
        feed(rec, x: 0.20, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.26, y: 0.50, fingers: 4)   // activate → anchor (0.26, 0.50)
        feed(rec, x: 0.26, y: 0.54, fingers: 4)   // dy offset +0.4 → band index round(0.4/1.0)=0 → none
        XCTAssertTrue(d.lContexts.isEmpty, "below the band step: no band switch")
        feed(rec, x: 0.26, y: 0.56, fingers: 4)   // dy offset +0.6 → band index 1 → one band switch
        XCTAssertEqual(d.lContexts, [1], "band switching uses the coarser band step")
        XCTAssertTrue(d.lItems.isEmpty, "pure vertical emits no horizontal item steps")
    }

    func test_horizontal_onBandList_usesItemStep() {
        // On the band list, HORIZONTAL (crossing toward the grid) is always the fine item step.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        d.onBandList = true
        feed(rec, x: 0.10, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.16, y: 0.50, fingers: 4)   // activate → anchor (0.16, 0.50)
        feed(rec, x: 0.22, y: 0.50, fingers: 4)   // dx offset +0.6 → item index 1 → one item step
        XCTAssertEqual(d.lItems, [1], "horizontal is the fine item step even on the band list")
        XCTAssertTrue(d.lContexts.isEmpty, "pure horizontal emits no vertical/band steps")
    }

    // MARK: - Margin acceleration (held-in-zone, 2D)
    //
    // Leaving the padding box (`|offset| ≥ paddingRadius`, here offset 2.0 = 0.20 of travel) — or entering
    // the edge band — accelerates: the recognizer reports a held sign via `launcherEdgeChanged` and the
    // controller auto-repeats. Each test relaxes to two fingers FIRST (re-anchoring the center there) and
    // only THEN pushes to the margin, so the re-anchor doesn't cancel the held signal.

    func test_holdDown_thenReleasesOnReturnToBox() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // relax to two → re-anchor at (0.56, 0.50)
        feed(rec, x: 0.56, y: 0.28, fingers: 2)   // hold DOWN: dy offset −2.2 ≥ box radius → held (0, −1)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [0, -1], "held down: dy = −1, dx = 0")
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // back into the box → released
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [0, 0])
    }

    func test_holdUp() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // relax → re-anchor
        feed(rec, x: 0.56, y: 0.72, fingers: 2)   // hold UP: dy offset +2.2 ≥ radius → held (0, +1)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [0, 1], "held up: dy = +1")
    }

    func test_holdRight() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // relax → re-anchor
        feed(rec, x: 0.78, y: 0.50, fingers: 2)   // hold RIGHT: dx offset +2.2 ≥ radius → held (+1, 0)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [1, 0], "held right: dx = +1")
    }

    func test_holdCorner_locksToDominantAxis() {
        // With the directional axis-lock the launcher commits a diagonal hold to the DOMINANT axis only —
        // it no longer reports both axes at once (change `launcher-aim-lock`).
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // relax → re-anchor at (0.56, 0.50)
        // Clearly left-dominant diagonal: x offset −2.2 (held), y offset +0.8 (frozen drift).
        feed(rec, x: 0.34, y: 0.58, fingers: 2)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [-1, 0], "the lock holds one axis (left), not both")
    }

    func test_holdPerfectDiagonal_commitsToNeither() {
        // A perfectly balanced 45° hold is ambiguous → the lock commits to neither axis (no held sign).
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // relax → re-anchor at (0.56, 0.50)
        feed(rec, x: 0.34, y: 0.72, fingers: 2)   // x offset −2.2, y offset +2.2 → tied → no commit
        XCTAssertNil(d.lastEdge, "an ambiguous diagonal emits no held-axis change")
    }

    func test_bandRailCrossing_upRightEntersItemsNotBand() {
        // On the band rail the WIDER rightward crossing wedge means an up-and-right stroke enters the items
        // (item steps) instead of switching a band — the "bigger crossing triangle" (change
        // `launcher-aim-lock`). The same 45°-ish angle would be ambiguous under the symmetric base wedge.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        d.onBandList = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate → anchor (0.56, 0.50)
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // relax → re-anchor
        feed(rec, x: 0.64, y: 0.57, fingers: 2)   // up-RIGHT: offset +0.8 / +0.7
        XCTAssertFalse(d.lItems.isEmpty, "the rightward stroke enters the items")
        XCTAssertTrue(d.lContexts.isEmpty, "the upward drift does not switch a band")
    }

    func test_edgeBand_acceleratesNearBorderInsideTheBox() {
        // The fixed edge band accelerates even when the offset is still inside the box radius.
        let (rec, d) = makeRecognizer(makeSettings(paddingRadius: 5.0), launcher: true)  // box won't trigger
        feed(rec, x: 0.80, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.86, y: 0.50, fingers: 4)   // activate → anchor (0.86, 0.50)
        feed(rec, x: 0.86, y: 0.50, fingers: 2)   // relax → re-anchor at (0.86, 0.50)
        feed(rec, x: 0.92, y: 0.50, fingers: 2)   // offset +0.6 (in box) BUT centroid 0.92 ≥ 0.90 edge band
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [1, 0], "near the border → accelerate via the edge band")
    }

    func test_held_isEmittedOnce_whileHeld() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // relax → re-anchor
        feed(rec, x: 0.56, y: 0.28, fingers: 2)   // into the margin (down) → one emit
        feed(rec, x: 0.56, y: 0.26, fingers: 2)   // further into the margin → no re-emit
        feed(rec, x: 0.56, y: 0.29, fingers: 2)   // still in the margin → no re-emit (reArmBackoff off)
        XCTAssertEqual(d.edges.count, 1, "held state is emitted only when it changes")
        XCTAssertEqual(d.edges.first.map { [$0.0, $0.1] }, [0, -1])
    }

    func test_liftAfterActivation_emitsEnd() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.40, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 0)   // lift
        XCTAssertEqual(d.lEndCount, 1)
        XCTAssertEqual(d.lCancelCount, 0)
    }

    func test_subThresholdThenLift_doesNotEnd() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.52, y: 0.50, fingers: 4)   // below activation
        feed(rec, x: 0.52, y: 0.50, fingers: 0)   // lift, never activated
        XCTAssertEqual(d.lEndCount, 0)
        XCTAssertTrue(d.events.isEmpty)
    }

    func test_fifthFinger_cancelsLauncher() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.40, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 5)   // 5th finger
        XCTAssertEqual(d.lCancelCount, 1)
        XCTAssertEqual(d.lEndCount, 0)
    }

    // MARK: - Launcher OFF preserves prior behavior

    func test_launcherDisabled_fourFingers_doNothing_whenExactlyThree() {
        let (rec, d) = makeRecognizer(makeSettings(requireExactlyThree: true), launcher: false)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)
        XCTAssertTrue(d.events.isEmpty, "with the launcher off, four fingers are ignored as before")
    }

    func test_launcherEnabled_threeFingerSwitcher_stillWorks() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.40, y: 0.50, fingers: 3)   // begin switcher
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // activate switcher
        feed(rec, x: 0.46, y: 0.50, fingers: 0)   // commit
        XCTAssertTrue(d.didSwitcherActivate)
        XCTAssertEqual(d.commitCount, 1)
        XCTAssertEqual(d.lActivateCount, 0, "a three-finger gesture never emits launcher intents")
    }

    func test_launcherEnabled_fourthFingerDuringThreeGesture_cancelsNoMorph() {
        // No mid-gesture morph: adding a 4th finger to a three-finger gesture cancels it (with
        // requireExactlyThree), it does not transform into a launcher gesture.
        let (rec, d) = makeRecognizer(makeSettings(requireExactlyThree: true), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 3)   // begin switcher
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // 4th finger → cancel switcher
        XCTAssertEqual(d.cancelCount, 1)
        XCTAssertEqual(d.lActivateCount, 0)
    }

    func test_reset_whileLauncherActive_cancels() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.40, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 4)   // activate
        rec.reset()
        XCTAssertEqual(d.lCancelCount, 1)
        XCTAssertEqual(d.lEndCount, 0)
    }

    // MARK: - Drop-to-two-finger navigation (latched launcher)

    func test_dropFourToThreeToTwo_staysLauncher_noSwitcherIntents() {
        // Relaxing four fingers to two passes transiently through three (the switcher's count). The
        // latched launcher must NOT hand off to the switcher and must NOT cancel.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.40, y: 0.50, fingers: 4)   // begin launcher
        feed(rec, x: 0.46, y: 0.50, fingers: 4)   // activate (dx 0.06 >= 0.045)
        feed(rec, x: 0.46, y: 0.50, fingers: 3)   // relax to three — re-baseline, no hand-off
        feed(rec, x: 0.46, y: 0.50, fingers: 2)   // relax to two   — re-baseline, no hand-off
        XCTAssertEqual(d.events, [.lActivate], "stays a launcher gesture; no switcher/cancel/end")
        XCTAssertFalse(d.didSwitcherActivate)
        XCTAssertEqual(d.cancelCount, 0)
        XCTAssertEqual(d.lCancelCount, 0)
        XCTAssertEqual(d.lEndCount, 0)
    }

    func test_centroidShiftOnCountChange_emitsNoStep_thenStepsAfterReanchor() {
        // A leaving finger moves the centroid; without re-anchoring that jump would read as a huge offset
        // and fire spurious steps. Assert zero steps from the count change (the positional center
        // re-anchors at the new posture), then a normal step from a push off the new center.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.20, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.26, y: 0.50, fingers: 4)   // activate → anchor (0.26, 0.50)
        feed(rec, x: 0.60, y: 0.80, fingers: 2)   // drop to two AND large jump → re-anchor, no step
        XCTAssertTrue(d.lItems.isEmpty, "centroid jump from a finger leaving emits no item step")
        XCTAssertTrue(d.lContexts.isEmpty, "centroid jump from a finger leaving emits no context step")
        feed(rec, x: 0.66, y: 0.80, fingers: 2)   // dx offset +0.6 from the NEW center → one item step
        XCTAssertEqual(d.lItems, [1])
        XCTAssertTrue(d.lContexts.isEmpty)
    }

    func test_endsBelowTwoContacts_notWhileTwoRemain() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.40, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.46, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.46, y: 0.50, fingers: 2)   // relax to two — still navigating, no end
        XCTAssertEqual(d.lEndCount, 0, "two contacts keep the launcher alive")
        feed(rec, x: 0.46, y: 0.50, fingers: 0)   // lift below two → end
        XCTAssertEqual(d.lEndCount, 1)
        XCTAssertEqual(d.lCancelCount, 0)
    }

    // MARK: - Canvas-resolution mode (a fresh TWO-finger swipe resolves the open AI canvas)
    //
    // Change `positional-navigation`, D5: the canvas resolves on two fingers (4 = open/dismiss the
    // platform, 2 = act within it), and the resolve excursion threshold (0.12) sits ABOVE incidental
    // scrolling so reading the canvas never resolves it.

    func test_canvasResolution_horizontal_emitsDiscard() {
        // While the canvas is open a fresh two-finger HORIZONTAL swipe past the resolve threshold resolves
        // it as a discard: dx != 0, dy == 0. No launcher/switcher intents are emitted.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // fresh two-finger contact (canvas resolution begin)
        feed(rec, x: 0.64, y: 0.50, fingers: 2)   // dx +0.14 (clearly horizontal) ≥ 0.12 → discard
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[1, 0]], "horizontal → discard (dx=+1)")
        XCTAssertEqual(d.lActivateCount, 0, "resolution mode never opens the launcher")
        XCTAssertFalse(d.didSwitcherActivate)
    }

    func test_canvasResolution_down_emitsApply() {
        // A two-finger DOWN swipe (y decreases in OMS coords) resolves as apply: dy = −1.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // begin
        feed(rec, x: 0.50, y: 0.36, fingers: 2)   // dy −0.14 (clearly vertical, downward) ≥ 0.12 → apply
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[0, -1]], "down → apply (dy=−1)")
    }

    func test_canvasResolution_up_emitsUp_ignoredUpstream() {
        // An UP swipe emits dy = +1; the coordinator ignores it (no apply, no discard), but the recognizer
        // still reports it so the wiring is exercised. Only the sign matters here.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // begin
        feed(rec, x: 0.50, y: 0.64, fingers: 2)   // dy +0.14 (upward) → dy=+1
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[0, 1]], "up → dy=+1 (ignored upstream)")
    }

    func test_canvasResolution_scrollBelowThresholdDoesNotResolve() {
        // The resolve excursion threshold (0.12) is ABOVE incidental scrolling: a small two-finger motion
        // (reading/scrolling the canvas) must NOT be mistaken for a commit/discard.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // begin
        feed(rec, x: 0.54, y: 0.56, fingers: 2)   // dx 0.04 / dy 0.06 both < 0.12 → scroll, not resolve
        XCTAssertTrue(d.canvasResolves.isEmpty, "a sub-threshold (scroll) motion never resolves")
        XCTAssertTrue(d.events.isEmpty)
    }

    func test_canvasResolution_emitsOncePerGesture() {
        // Once resolved, continued travel within the same contact does NOT emit again (one swipe = one
        // resolution). A lift re-arms it for the next swipe.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // begin
        feed(rec, x: 0.64, y: 0.50, fingers: 2)   // resolve discard
        feed(rec, x: 0.78, y: 0.50, fingers: 2)   // more travel — must NOT re-emit
        feed(rec, x: 0.50, y: 0.30, fingers: 2)   // even a vertical excursion — still no re-emit
        XCTAssertEqual(d.canvasResolves.count, 1, "exactly one resolution per gesture")
    }

    func test_canvasResolution_twoFingerStartResolves() {
        // Two fingers resolve the canvas (change `positional-navigation`, D5 — 2 = act within the platform).
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // a fresh two-finger contact begins resolution
        feed(rec, x: 0.64, y: 0.50, fingers: 2)   // dx +0.14 ≥ 0.12 → discard
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[1, 0]], "two fingers resolve the canvas")
    }

    func test_canvasResolution_liftReArmsForNextSwipe() {
        // After a resolution + lift, a second fresh two-finger swipe resolves again (the model would
        // normally have closed the canvas, but the recognizer's one-shot must reset on lift regardless).
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // begin
        feed(rec, x: 0.64, y: 0.50, fingers: 2)   // resolve #1 (discard)
        feed(rec, x: 0.64, y: 0.50, fingers: 0)   // lift → re-arm
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // begin again
        feed(rec, x: 0.50, y: 0.36, fingers: 2)   // resolve #2 (down → apply)
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[1, 0], [0, -1]], "lift re-arms resolution")
    }

    func test_canvasResolution_relaxToTwoFingers_stillResolves() {
        // Matching the launcher latch feel: after a four-finger start the user may relax to two and the
        // swipe still resolves.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.50, y: 0.38, fingers: 2)   // relaxed to two AND a downward excursion → apply
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[0, -1]])
    }
}
