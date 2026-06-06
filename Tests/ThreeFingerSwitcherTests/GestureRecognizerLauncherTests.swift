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
    }
    private(set) var events: [Event] = []

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

    var lActivateCount: Int { events.filter { $0 == .lActivate }.count }
    var lEndCount: Int { events.filter { $0 == .lEnd }.count }
    var lCancelCount: Int { events.filter { $0 == .lCancel }.count }
    var lItems: [Int] { events.compactMap { if case let .lItem(d) = $0 { return d } else { return nil } } }
    var lContexts: [Int] { events.compactMap { if case let .lContext(d) = $0 { return d } else { return nil } } }
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

    func test_contextStepping_verticalTravel() {
        let (rec, d) = makeRecognizer(makeSettings(launcherContextStepDistance: 0.10), launcher: true)
        feed(rec, x: 0.20, y: 0.50, fingers: 4)   // begin
        feed(rec, x: 0.26, y: 0.50, fingers: 4)   // activate
        feed(rec, x: 0.26, y: 0.701, fingers: 4)  // dy +0.201 → 2 context steps up
        XCTAssertEqual(d.lContexts, [1, 1])
        XCTAssertTrue(d.lItems.isEmpty, "pure vertical emits no item steps")
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
}
