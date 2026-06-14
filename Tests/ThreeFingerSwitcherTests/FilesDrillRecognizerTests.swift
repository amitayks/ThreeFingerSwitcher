import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Records the Files-drill intents (plus the switcher/launcher activation intents) so tests can assert
/// the recognizer's sustained modal sub-state emits depth/highlight/open/open-with/discard correctly and
/// — crucially — that while `filesDrillActive` a fresh contact never routes to the switcher or launcher.
@MainActor
private final class FilesDrillMockDelegate: GestureRecognizerDelegate {
    enum Event: Equatable {
        case depth(Int), highlight(Int), open, openWith, discard
        case edge(Int, Int)   // launcherEdgeChanged(dx,dy): the held-at-edge sign that drives auto-repeat
        // Tripwires: these MUST stay empty while drilling (the latch is bypassed).
        case sActivate, lActivate
    }
    private(set) var events: [Event] = []

    // Files drill
    func filesDepth(_ d: Int) { events.append(.depth(d)) }
    func filesHighlight(_ d: Int) { events.append(.highlight(d)) }
    func filesOpen() { events.append(.open) }
    func filesOpenWith() { events.append(.openWith) }
    func filesDiscard() { events.append(.discard) }
    // The held-at-edge sign (depth/highlight border auto-repeat): the recognizer publishes it through the
    // launcher edge delegate, and the controller turns it into edge-triggered auto-repeat.
    func launcherEdgeChanged(dx: Int, dy: Int) { events.append(.edge(dx, dy)) }

    // Tripwires (must never fire during a drill)
    func gestureDidActivate() { events.append(.sActivate) }
    func launcherDidActivate() { events.append(.lActivate) }
    // The remaining base switcher intents have no protocol default (only the launcher / files-drill
    // intents do), so they must be stubbed. They are not asserted here — while drilling, the bypass
    // means a fresh contact never re-latches the switcher, so these stay silent — so plain no-ops.
    func gestureDidStep(_ direction: Int) {}
    func gestureDidStepRow(_ direction: Int) {}
    func gestureDidTriggerMissionControl(up: Bool) {}
    func gestureDidCommit() {}
    func gestureDidCancel() {}
    // The launcher and files-drill intents not overridden above are left to the protocol's default no-ops.

    var depths: [Int] { events.compactMap { if case let .depth(d) = $0 { return d } else { return nil } } }
    var highlights: [Int] { events.compactMap { if case let .highlight(d) = $0 { return d } else { return nil } } }
    var lastEdgeDX: Int? { events.reversed().compactMap { if case let .edge(dx, _) = $0 { return dx } else { return nil } }.first }
    var openCount: Int { events.filter { $0 == .open }.count }
    var openWithCount: Int { events.filter { $0 == .openWith }.count }
    var discardCount: Int { events.filter { $0 == .discard }.count }
    var didSwitcherActivate: Bool { events.contains(.sActivate) }
    var didLauncherActivate: Bool { events.contains(.lActivate) }
}

@MainActor
final class FilesDrillRecognizerTests: XCTestCase {

    // MARK: - Fixture

    /// The drill navigation is the **odometer** (restored v0.11.0 model) on BOTH axes: `launcherStepDistance`
    /// is the per-step travel distance, so a centroid Δ of one step emits one depth/highlight step (with
    /// carry), and holding a contact at a trackpad edge sets the held sign so the controller auto-repeats —
    /// uniform on both axes (depth auto-drills the folder tree). `launcherActivationThreshold` is the
    /// four-finger discard-swipe threshold; `axisLockRatio` gates the discard to a horizontal-dominant
    /// sweep. With step 0.1, a centroid Δ of 0.15 ≈ one step and 0.35 ≈ three steps.
    private func makeSettings(
        launcherActivationThreshold: Double = 0.045,
        step: Double = 0.1,
        axisLockRatio: Double = 1.4,
        reverseDirection: Bool = false,
        reverseVerticalDirection: Bool = false
    ) -> AppSettings {
        let defaults = UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.launcherActivationThreshold = launcherActivationThreshold
        settings.launcherStepDistance = step                  // odometer step (travel per depth/highlight step)
        settings.axisLockRatio = axisLockRatio
        settings.reverseDirection = reverseDirection
        settings.reverseVerticalDirection = reverseVerticalDirection
        return settings
    }

    /// Builds a recognizer already in the drill sub-state (the controller flips the flag when the Files
    /// navigator opens). `launcherEnabled` is left ON so the bypass tests prove the drill pre-empts the
    /// four-finger launcher latch too.
    private func makeDrillRecognizer(_ settings: AppSettings) -> (GestureRecognizer, FilesDrillMockDelegate) {
        let delegate = FilesDrillMockDelegate()
        let rec = GestureRecognizer(settings: settings)
        rec.delegate = delegate
        rec.launcherEnabled = true
        rec.filesDrillActive = true
        return (rec, delegate)
    }

    private func feed(_ rec: GestureRecognizer, x: Double, y: Double, fingers: Int) {
        rec.feed(TouchFrame(testFingerCount: fingers, centroid: CGPoint(x: x, y: y)))
    }

    // MARK: - Depth (horizontal) / Highlight (vertical)

    func test_horizontalTravel_odometerDepth() {
        // Depth is the odometer: a +0.35 sweep (≈3 steps) descends three levels with carry; moving back
        // steps it back (ascends). The first ≥2-finger frame seeds the origin.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // seed (0.20, 0.50)
        feed(rec, x: 0.55, y: 0.50, fingers: 2)    // Δx +0.35 → +3 depth steps
        XCTAssertEqual(d.depths, [1, 1, 1], "depth accumulates one step per step-distance of travel")
        XCTAssertTrue(d.highlights.isEmpty, "pure horizontal emits no highlight steps")
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // Δx −0.35 → 3 depth steps back (ascend)
        XCTAssertEqual(d.depths, [1, 1, 1, -1, -1, -1])
    }

    func test_horizontalHeldAtBorder_setsDepthHeldSign_forAutoRepeat() {
        // Uniform auto-repeat: holding depth at the trackpad border sets the HORIZONTAL held sign, so the
        // controller auto-drills (the border acceleration the user asked for).
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // seed mid-trackpad
        feed(rec, x: 0.96, y: 0.50, fingers: 2)    // push into the right edge zone → depth held
        XCTAssertEqual(d.lastEdgeDX, 1, "holding depth at the border sets the horizontal held sign")
        XCTAssertFalse(d.depths.isEmpty, "and the depth stepped on the way out")
    }

    func test_verticalTravel_odometerHighlight() {
        // Highlight is the odometer too: a +0.35 vertical sweep moves the highlight three rows; moving
        // back steps it back.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.20, fingers: 2)    // seed (0.50, 0.20)
        feed(rec, x: 0.50, y: 0.55, fingers: 2)    // Δy +0.35 → +3 highlight steps
        XCTAssertEqual(d.highlights, [1, 1, 1], "the highlight accumulates one step per step-distance")
        XCTAssertTrue(d.depths.isEmpty, "pure vertical emits no depth steps")
        feed(rec, x: 0.50, y: 0.20, fingers: 2)    // Δy −0.35 → 3 highlight steps back
        XCTAssertEqual(d.highlights, [1, 1, 1, -1, -1, -1])
    }

    func test_directionInversion_isHonored_onBothAxes() {
        // The drill applies the SAME reverseDirection / reverseVerticalDirection as the launcher: a forward
        // (+x / +y) push flips to -1 when inverted.
        let (rec, d) = makeDrillRecognizer(makeSettings(reverseDirection: true, reverseVerticalDirection: true))
        feed(rec, x: 0.20, y: 0.20, fingers: 2)    // seed
        feed(rec, x: 0.35, y: 0.20, fingers: 2)    // +x push (1 step), inverted → depth -1
        XCTAssertEqual(d.depths, [-1])
        feed(rec, x: 0.20, y: 0.20, fingers: 2)    // back (steps the depth the other way)
        feed(rec, x: 0.20, y: 0.35, fingers: 2)    // +y push (1 step), inverted → highlight -1
        XCTAssertEqual(d.highlights, [-1])
    }

    func test_negativeTravel_emitsNegativeDepthSteps() {
        // Leftward depth ascends: a −0.35 sweep → −3 steps.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.80, y: 0.50, fingers: 3)    // seed at three fingers (still the relaxed posture)
        feed(rec, x: 0.45, y: 0.50, fingers: 3)    // Δx −0.35 → −3 depth steps
        XCTAssertEqual(d.depths, [-1, -1, -1])
    }

    // MARK: - Re-baseline on contact-count change (no phantom step)

    func test_contactCountChange_reBaselines_emitsNoPhantomStep() {
        // A finger leaving shifts the centroid; without re-baselining that jump would read as a huge travel
        // and fire spurious steps. Assert zero steps from the count change, then one step from a push.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.20, fingers: 3)    // seed at three
        feed(rec, x: 0.60, y: 0.80, fingers: 2)    // drop to two AND a large jump → re-baseline, no step
        XCTAssertTrue(d.depths.isEmpty, "the count-change centroid jump emits no depth step")
        XCTAssertTrue(d.highlights.isEmpty, "the count-change centroid jump emits no highlight step")
        feed(rec, x: 0.75, y: 0.80, fingers: 2)    // Δx +0.15 from the NEW baseline → one depth step
        XCTAssertEqual(d.depths, [1])
        XCTAssertTrue(d.highlights.isEmpty)
    }

    func test_landingFinger_alsoReBaselines() {
        // Symmetric to a leaving finger: a landing finger re-baselines too, so the centroid jump emits no step.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // seed at two
        feed(rec, x: 0.55, y: 0.50, fingers: 3)    // a finger lands; big jump → re-baseline, no step
        XCTAssertTrue(d.depths.isEmpty)
        feed(rec, x: 0.70, y: 0.50, fingers: 3)    // Δx +0.15 from the new baseline → one depth step
        XCTAssertEqual(d.depths, [1])
    }

    // MARK: - Relative +1 finger → Open-With on the lift

    func test_relativePlusOne_fromTwoToThree_liftEmitsOpenWith() {
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // seed; relaxed baseline = 2
        feed(rec, x: 0.50, y: 0.50, fingers: 3)    // +1 above baseline → latch Open-With (no step)
        feed(rec, x: 0.50, y: 0.50, fingers: 0)    // resolving lift
        XCTAssertEqual(d.openWithCount, 1, "a relative +1 finger resolves Open-With")
        XCTAssertEqual(d.openCount, 0)
    }

    func test_relativePlusOne_baselineThreeToFour_isOpenWithNotDiscard() {
        // The trigger is "a finger was added above the baseline", not "exactly three": a baseline of three
        // rising to four is the Open-With morph; a plain lift from four (no swipe) resolves Open-With.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 3)    // seed; relaxed baseline = 3
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // 3 → 4: relative +1, latch Open-With
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // hold four, no swipe → no discard
        feed(rec, x: 0.50, y: 0.50, fingers: 0)    // lift → Open-With
        XCTAssertEqual(d.openWithCount, 1)
        XCTAssertEqual(d.discardCount, 0, "four fingers WITHOUT a swipe-away is Open-With, not discard")
        XCTAssertEqual(d.openCount, 0)
    }

    func test_noAddedFinger_liftEmitsPlainOpen() {
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // seed
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // navigate (depth steps), no finger added
        feed(rec, x: 0.50, y: 0.50, fingers: 0)    // resolving lift → plain Open
        XCTAssertEqual(d.openCount, 1)
        XCTAssertEqual(d.openWithCount, 0)
    }

    // MARK: - Four-finger horizontal swipe → discard

    func test_fourFingerHorizontalSwipe_emitsDiscard() {
        // A fresh deliberate four-finger horizontal swipe-away resolves discard — and does NOT spray depth
        // steps on the way (the four-finger arming posture suppresses navigation).
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // seed at four (the arming posture)
        feed(rec, x: 0.20, y: 0.50, fingers: 4)    // dx -0.30 ≥ 0.045, horizontal-dominant → discard
        XCTAssertEqual(d.discardCount, 1)
        XCTAssertTrue(d.depths.isEmpty, "the four-finger swipe-away emits no depth steps")
    }

    func test_fourFingerDiscard_winsOverPendingOpenWith() {
        // Relaxed baseline two → four is a relative +1 (latches Open-With), but a deliberate four-finger
        // horizontal swipe resolves discard and the later lift emits nothing (one-shot).
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // seed; baseline = 2
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // 2 → 4: latches Open-With AND re-baselines origin
        feed(rec, x: 0.18, y: 0.50, fingers: 4)    // big horizontal sweep → discard
        feed(rec, x: 0.18, y: 0.50, fingers: 0)    // lift after a resolution → no-op
        XCTAssertEqual(d.discardCount, 1)
        XCTAssertEqual(d.openWithCount, 0, "discard pre-empts the latched Open-With")
        XCTAssertEqual(d.openCount, 0)
    }

    func test_fourFingerSmallNudge_doesNotDiscard() {
        // A small horizontal nudge at four fingers is below the discard threshold: no discard, and (arming
        // posture) no depth steps either; a lift then resolves Open-With from the +1.
        let (rec, d) = makeDrillRecognizer(makeSettings(launcherActivationThreshold: 0.045))
        feed(rec, x: 0.50, y: 0.50, fingers: 3)    // seed; baseline = 3
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // 3 → 4: latch Open-With, re-baseline
        feed(rec, x: 0.52, y: 0.50, fingers: 4)    // dx +0.02 < 0.045 → no discard
        XCTAssertEqual(d.discardCount, 0)
        XCTAssertTrue(d.depths.isEmpty)
        feed(rec, x: 0.52, y: 0.50, fingers: 0)    // lift → Open-With
        XCTAssertEqual(d.openWithCount, 1)
    }

    func test_fourFingerVerticalSweep_doesNotDiscard() {
        // Discard is a HORIZONTAL swipe-away; a vertical sweep at four fingers is not horizontal-dominant,
        // so it does not discard (the axis-lock ratio gates it).
        let (rec, d) = makeDrillRecognizer(makeSettings(axisLockRatio: 1.4))
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // seed at four
        feed(rec, x: 0.50, y: 0.18, fingers: 4)    // dy -0.32, dx 0 → not horizontal → no discard
        XCTAssertEqual(d.discardCount, 0)
    }

    // MARK: - One-shot resolution (a stray re-lift is a no-op)

    func test_resolution_isOneShot_strayReLiftEmitsNothing() {
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // seed
        feed(rec, x: 0.35, y: 0.50, fingers: 2)    // navigate: Δx +0.15 → one depth step
        feed(rec, x: 0.35, y: 0.50, fingers: 0)    // lift → Open (resolved)
        XCTAssertEqual(d.openCount, 1)
        // A stray re-lift: fingers return, then lift again — must emit nothing further.
        feed(rec, x: 0.40, y: 0.50, fingers: 2)    // fingers return (re-seed only)
        feed(rec, x: 0.60, y: 0.50, fingers: 2)    // travel while resolved → no steps
        feed(rec, x: 0.60, y: 0.50, fingers: 0)    // re-lift → no second resolution
        XCTAssertEqual(d.openCount, 1, "the resolution is one-shot for the whole session")
        XCTAssertEqual(d.openWithCount, 0)
        XCTAssertEqual(d.depths, [1], "no NEW navigation steps after the session resolved")
    }

    func test_reEntry_clearsResolvedState_forANewSession() {
        // The controller flips the flag off on hide and on again when the navigator re-opens; the didSet
        // re-seeds a fresh session, so a new Open can resolve.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // seed
        feed(rec, x: 0.50, y: 0.50, fingers: 0)    // lift → Open (resolved)
        XCTAssertEqual(d.openCount, 1)
        rec.filesDrillActive = false               // navigator hides
        rec.filesDrillActive = true                // navigator re-opens → fresh session
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // seed again
        feed(rec, x: 0.50, y: 0.50, fingers: 0)    // lift → a SECOND Open
        XCTAssertEqual(d.openCount, 2, "re-entering the sub-state clears the one-shot resolution")
    }

    // MARK: - Lift debounce (edge flicker is not a resolution)

    func test_singleFingerFlicker_doesNotResolve_butSustainedDropDoes() {
        // A momentary dip to one finger (an edge flicker) is debounced — only a true lift (0) or a
        // sustained drop below two resolves. Mirrors the launcher's belowTargetFrames >= 2 rule.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // seed
        feed(rec, x: 0.50, y: 0.50, fingers: 1)    // one frame at 1 → debounced, no resolution
        XCTAssertEqual(d.openCount, 0, "a single below-two frame is debounced")
        feed(rec, x: 0.50, y: 0.50, fingers: 1)    // a second below-two frame → sustained drop → resolve
        XCTAssertEqual(d.openCount, 1)
    }

    // MARK: - Bypass: a fresh contact never routes to the switcher / launcher

    func test_drillActive_freshThreeFingerContact_doesNotOpenSwitcher() {
        // While drilling, a fresh three-finger contact + horizontal scrub routes to the drill (depth steps),
        // never to the switcher — the early short-circuit bypasses the idle re-latch.
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 3)    // fresh three-finger contact (would normally arm switcher)
        feed(rec, x: 0.35, y: 0.50, fingers: 3)    // horizontal push, Δx +0.15 → one depth step
        XCTAssertFalse(d.didSwitcherActivate, "a fresh contact during drill never opens the switcher")
        XCTAssertEqual(d.depths, [1], "it routes to the drill instead")
    }

    func test_drillActive_freshFourFingerContact_doesNotOpenLauncher() {
        // A fresh four-finger contact during drill must not open a second launcher on top of the navigator;
        // it routes to the drill (here: the four-finger arming posture, resolved by a horizontal discard).
        let (rec, d) = makeDrillRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // fresh four-finger contact (would normally arm launcher)
        feed(rec, x: 0.20, y: 0.50, fingers: 4)    // horizontal sweep → discard (drill), not launcher
        XCTAssertFalse(d.didLauncherActivate, "a fresh four-finger contact during drill never opens the launcher")
        XCTAssertEqual(d.discardCount, 1)
    }
}
