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

    private func makeSettings(
        launcherActivationThreshold: Double = 0.045,
        launcherStepDistance: Double = 0.05,
        launcherContextStepDistance: Double = 0.10,
        requireExactlyThree: Bool = true
    ) -> AppSettings {
        let defaults = UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.launcherActivationThreshold = launcherActivationThreshold
        settings.launcherStepDistance = launcherStepDistance
        settings.launcherContextStepDistance = launcherContextStepDistance
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

    func test_itemStepping_horizontalTravel() {
        let (rec, d) = makeRecognizer(makeSettings(launcherStepDistance: 0.05), launcher: true)
        feed(rec, x: 0.10, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.16, y: 0.50, fingers: 4)   // activate (lastCentroid x=0.16)
        feed(rec, x: 0.311, y: 0.50, fingers: 4)  // +0.151 → 3 item steps
        XCTAssertEqual(d.lItems, [1, 1, 1])
    }

    func test_verticalStepping_inGrid_usesItemStep() {
        // In the grid (NOT on the band list), vertical travel steps grid rows at the fine ITEM-step
        // threshold — band switching is no longer the vertical axis here, so the coarser context/band
        // threshold does not apply. (`onBandList` defaults to false → the grid case.)
        let (rec, d) = makeRecognizer(makeSettings(launcherStepDistance: 0.05,
                                                   launcherContextStepDistance: 0.10), launcher: true)
        feed(rec, x: 0.20, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.26, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.26, y: 0.651, fingers: 4)  // dy +0.151 at the 0.05 item step → 3 vertical steps
        XCTAssertEqual(d.lContexts, [1, 1, 1], "grid rows step at the item-step, not the band threshold")
        XCTAssertTrue(d.lItems.isEmpty, "pure vertical emits no horizontal steps")
    }

    func test_bandSwitch_onBandList_usesBandThreshold_onVertical() {
        // On the band list, VERTICAL travel switches bands at the coarser context/band step, so the same
        // vertical travel yields fewer steps than the fine item-step — the band gate moved to the
        // vertical axis. Band switching is reported via `launcherDidStepContext` (→ `lContexts`).
        let (rec, d) = makeRecognizer(makeSettings(launcherStepDistance: 0.05,
                                                   launcherContextStepDistance: 0.10), launcher: true)
        d.onBandList = true
        feed(rec, x: 0.20, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.26, y: 0.50, fingers: 4)   // activate (dx 0.06 ≥ 0.045)
        feed(rec, x: 0.26, y: 0.701, fingers: 4)  // dy +0.201 at the 0.10 band step → 2 steps
        XCTAssertEqual(d.lContexts, [1, 1], "band switching on the band list steps at the band threshold")
        XCTAssertTrue(d.lItems.isEmpty, "pure vertical emits no horizontal item steps")
        // The same +0.201 vertical travel in the grid (item step 0.05) would be 4 steps — see the
        // in-grid vertical-stepping test.
    }

    func test_horizontal_onBandList_usesItemStep() {
        // On the band list, HORIZONTAL travel (crossing toward the grid / item movement) is always the
        // fine item-step, never the coarse band gate — only the vertical axis carries the band gate.
        let (rec, d) = makeRecognizer(makeSettings(launcherStepDistance: 0.05,
                                                   launcherContextStepDistance: 0.10), launcher: true)
        d.onBandList = true
        feed(rec, x: 0.10, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.16, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.311, y: 0.50, fingers: 4)  // dx +0.151 at the 0.05 item step → 3 item steps
        XCTAssertEqual(d.lItems, [1, 1, 1], "horizontal is the fine item-step even on the band list")
        XCTAssertTrue(d.lContexts.isEmpty, "pure horizontal emits no vertical/band steps")
    }

    // MARK: - Edge-hold for auto-repeat (2D)

    func test_bottomEdge_holdsDown_thenReleasesOnLeave() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.10, fingers: 2)   // centroid near the BOTTOM edge (y ≤ enter zone)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [0, -1], "bottom edge: dy = −1, dx = 0")
        feed(rec, x: 0.56, y: 0.50, fingers: 2)   // back to centre → no edge
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [0, 0])
    }

    func test_topEdge_holdsUp() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.90, fingers: 2)   // TOP edge (y ≥ 1 − enter zone)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [0, 1], "top edge: dy = +1")
    }

    func test_rightEdge_holdsRight() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.90, y: 0.50, fingers: 2)   // RIGHT edge (x ≥ 1 − enter zone)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [1, 0], "right edge: dx = +1")
    }

    func test_corner_holdsBothAxes() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.08, y: 0.92, fingers: 2)   // bottom-left… x low (−1), y high (+1)
        XCTAssertEqual(d.lastEdge.map { [$0.0, $0.1] }, [-1, 1], "a corner reports both axes")
    }

    func test_edge_isEmittedOnce_whileHeld() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        feed(rec, x: 0.50, y: 0.50, fingers: 4)
        feed(rec, x: 0.56, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.56, y: 0.10, fingers: 2)   // enter bottom edge → one emit
        feed(rec, x: 0.56, y: 0.08, fingers: 2)   // still within exit zone → no re-emit
        feed(rec, x: 0.56, y: 0.12, fingers: 2)   // still within exit zone → no re-emit
        XCTAssertEqual(d.edges.count, 1, "edge state is emitted only when it changes")
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

    func test_centroidShiftOnCountChange_emitsNoStep_thenStepsAfterBaseline() {
        // A leaving finger moves the centroid; without re-baselining that jump would fire spurious
        // steps. Assert zero steps from the count change, then normal steps from later movement.
        let (rec, d) = makeRecognizer(makeSettings(launcherStepDistance: 0.05,
                                                   launcherContextStepDistance: 0.10), launcher: true)
        feed(rec, x: 0.20, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.26, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.60, y: 0.80, fingers: 2)   // drop to two AND large centroid jump → no step
        XCTAssertTrue(d.lItems.isEmpty, "centroid jump from a finger leaving emits no item step")
        XCTAssertTrue(d.lContexts.isEmpty, "centroid jump from a finger leaving emits no context step")
        feed(rec, x: 0.751, y: 0.80, fingers: 2)  // +0.151 from the new baseline → 3 item steps
        XCTAssertEqual(d.lItems, [1, 1, 1])
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

    // MARK: - Canvas-resolution mode (a fresh four-finger swipe resolves the open AI canvas)

    func test_canvasResolution_horizontal_emitsDiscard() {
        // While the canvas is open a fresh four-finger HORIZONTAL swipe past the threshold resolves it
        // as a discard: dx != 0, dy == 0. No launcher/switcher intents are emitted.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // fresh four-finger contact (canvas resolution begin)
        feed(rec, x: 0.62, y: 0.50, fingers: 4)   // dx +0.12 (clearly horizontal) ≥ 0.045 → discard
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[1, 0]], "horizontal → discard (dx=+1)")
        XCTAssertEqual(d.lActivateCount, 0, "resolution mode never opens the launcher")
        XCTAssertFalse(d.didSwitcherActivate)
    }

    func test_canvasResolution_down_emitsApply() {
        // A DOWN swipe (y decreases in OMS coords) resolves as apply: dy = −1 ("bring it to the document").
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.50, y: 0.38, fingers: 4)   // dy −0.12 (clearly vertical, downward) → apply
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[0, -1]], "down → apply (dy=−1)")
    }

    func test_canvasResolution_up_emitsUp_ignoredUpstream() {
        // An UP swipe emits dy = +1; the coordinator ignores it (no apply, no discard), but the recognizer
        // still reports it so the wiring is exercised. Only the sign matters here.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.50, y: 0.62, fingers: 4)   // dy +0.12 (upward) → dy=+1
        XCTAssertEqual(d.canvasResolves.map { [$0.0, $0.1] }, [[0, 1]], "up → dy=+1 (ignored upstream)")
    }

    func test_canvasResolution_subThreshold_emitsNothing() {
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.52, y: 0.51, fingers: 4)   // dx 0.02 / dy 0.01 both < 0.045 → nothing
        XCTAssertTrue(d.canvasResolves.isEmpty, "a sub-threshold swipe never resolves")
        XCTAssertTrue(d.events.isEmpty)
    }

    func test_canvasResolution_emitsOncePerGesture() {
        // Once resolved, continued travel within the same contact does NOT emit again (one swipe = one
        // resolution). A lift re-arms it for the next swipe.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.62, y: 0.50, fingers: 4)   // resolve discard
        feed(rec, x: 0.74, y: 0.50, fingers: 4)   // more travel — must NOT re-emit
        feed(rec, x: 0.50, y: 0.30, fingers: 4)   // even a vertical excursion — still no re-emit
        XCTAssertEqual(d.canvasResolves.count, 1, "exactly one resolution per gesture")
    }

    func test_canvasResolution_requiresFreshFourFingerStart() {
        // A swipe that begins with fewer than four fingers must not resolve — the gesture has to start
        // from a deliberate four-finger contact, mirroring how the launcher itself is opened.
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 2)   // only two fingers down — no begin
        feed(rec, x: 0.62, y: 0.50, fingers: 2)   // travel — must NOT resolve
        XCTAssertTrue(d.canvasResolves.isEmpty, "resolution requires a fresh four-finger start")
    }

    func test_canvasResolution_liftReArmsForNextSwipe() {
        // After a resolution + lift, a second fresh four-finger swipe resolves again (the model would
        // normally have closed the canvas, but the recognizer's one-shot must reset on lift regardless).
        let (rec, d) = makeRecognizer(makeSettings(), launcher: true)
        rec.launcherCanvasResolutionActive = true
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.62, y: 0.50, fingers: 4)   // resolve #1 (discard)
        feed(rec, x: 0.62, y: 0.50, fingers: 0)   // lift → re-arm
        feed(rec, x: 0.50, y: 0.50, fingers: 4)   // begin again
        feed(rec, x: 0.50, y: 0.38, fingers: 4)   // resolve #2 (down → apply)
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
