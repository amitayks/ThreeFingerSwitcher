import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Records the player transport intents (plus the switcher/launcher activation tripwires) so tests can
/// assert the recognizer's sustained player sub-state emits seek/volume/toggle/action-menu/select/dismiss
/// correctly and — crucially — that while `playerActive` a fresh contact never routes to the switcher or
/// launcher (a three-finger count is the action menu, NOT the window switcher).
@MainActor
private final class PlayerMockDelegate: GestureRecognizerDelegate {
    enum Event: Equatable {
        case seek(Int), volume(Int), toggle, actionMenu, select, dismiss
        case held(Int, Int)
        // Tripwires: these MUST stay empty while the player is active (the latch is bypassed).
        case sActivate, lActivate
    }
    private(set) var events: [Event] = []

    func playerSeek(_ d: Int) { events.append(.seek(d)) }
    func playerVolume(_ d: Int) { events.append(.volume(d)) }
    func playerTogglePlayPause() { events.append(.toggle) }
    func playerActionMenu() { events.append(.actionMenu) }
    func playerSelectMenuItem() { events.append(.select) }
    func playerDismiss() { events.append(.dismiss) }
    func playerHeldZoneChanged(dx: Int, dy: Int) { events.append(.held(dx, dy)) }

    // Tripwires (must never fire while the player is active)
    func gestureDidActivate() { events.append(.sActivate) }
    func launcherDidActivate() { events.append(.lActivate) }
    // Base switcher intents have no protocol default, so they must be stubbed (never asserted here).
    func gestureDidStep(_ direction: Int) {}
    func gestureDidStepRow(_ direction: Int) {}
    func gestureDidTriggerMissionControl(up: Bool) {}
    func gestureDidCommit() {}
    func gestureDidCancel() {}

    var seeks: [Int] { events.compactMap { if case let .seek(d) = $0 { return d } else { return nil } } }
    var volumes: [Int] { events.compactMap { if case let .volume(d) = $0 { return d } else { return nil } } }
    var toggles: Int { events.filter { $0 == .toggle }.count }
    var actionMenus: Int { events.filter { $0 == .actionMenu }.count }
    var selects: Int { events.filter { $0 == .select }.count }
    var dismisses: Int { events.filter { $0 == .dismiss }.count }
    var heldSigns: [Event] { events.filter { if case .held = $0 { return true } else { return false } } }
    var didSwitcherActivate: Bool { events.contains(.sActivate) }
    var didLauncherActivate: Bool { events.contains(.lActivate) }
}

@MainActor
final class PlayerDrillRecognizerTests: XCTestCase {

    /// Same positional fixture as the Files drill: `launcherStepDistance` is the outer threshold (offset
    /// units), test frames carry no footprint so the offset uses `fallbackScale`. With fallbackScale 0.1
    /// and outer 0.5, an offset of `outer` is reached at ~0.05 of centroid travel from the anchor.
    private func makeSettings(reverseDirection: Bool = false,
                              reverseVerticalDirection: Bool = false) -> AppSettings {
        let defaults = UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!
        let s = AppSettings(defaults: defaults)
        s.launcherStepDistance = 0.5
        s.positionalInnerDeadzone = 0.2
        s.positionalFallbackScale = 0.1
        s.axisLockRatio = 1.4
        s.reverseDirection = reverseDirection
        s.reverseVerticalDirection = reverseVerticalDirection
        return s
    }

    private func makePlayerRecognizer(_ settings: AppSettings) -> (GestureRecognizer, PlayerMockDelegate) {
        let delegate = PlayerMockDelegate()
        let rec = GestureRecognizer(settings: settings)
        rec.delegate = delegate
        rec.launcherEnabled = true      // ON so the bypass tests prove the player pre-empts the launcher latch
        rec.playerActive = true
        return (rec, delegate)
    }

    private func feed(_ rec: GestureRecognizer, x: Double, y: Double, fingers: Int) {
        rec.feed(TouchFrame(testFingerCount: fingers, centroid: CGPoint(x: x, y: y)))
    }

    // MARK: - Bypass / tripwires

    func test_threeFingers_doNotActivateSwitcher() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 3)    // seeds at 3 fingers
        feed(rec, x: 0.56, y: 0.50, fingers: 3)    // movement
        XCTAssertFalse(d.didSwitcherActivate, "a 3-finger count must not open the window switcher")
        XCTAssertFalse(d.didLauncherActivate, "nor the launcher")
    }

    // MARK: - Seek / volume + held sign (both axes auto-repeat)

    func test_horizontalEmitsSeekAndHeldSign() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // seed/anchor (no step)
        feed(rec, x: 0.26, y: 0.50, fingers: 2)    // offset +0.6 > outer 0.5 → one seek + held
        XCTAssertEqual(d.seeks, [1])
        XCTAssertTrue(d.volumes.isEmpty, "pure horizontal emits no volume steps")
        XCTAssertTrue(d.heldSigns.contains(.held(1, 0)), "a held horizontal offset signals auto-repeat")
    }

    func test_verticalEmitsVolumeAndHeldSign() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.20, fingers: 2)    // seed/anchor
        feed(rec, x: 0.50, y: 0.26, fingers: 2)    // offset +0.6 → one volume + held
        XCTAssertEqual(d.volumes, [1])
        XCTAssertTrue(d.seeks.isEmpty, "pure vertical emits no seek steps")
        XCTAssertTrue(d.heldSigns.contains(.held(0, 1)), "volume axis also auto-repeats")
    }

    // MARK: - Tap toggles; scrub-then-lift does not

    func test_tapTogglesPlayPause() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // contact, no movement
        feed(rec, x: 0.50, y: 0.50, fingers: 0)    // lift → tap → toggle
        XCTAssertEqual(d.toggles, 1)
    }

    func test_scrubThenLift_doesNotToggle() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // seed
        feed(rec, x: 0.30, y: 0.50, fingers: 2)    // a real scrub (seek)
        feed(rec, x: 0.30, y: 0.50, fingers: 0)    // lift → NOT a tap
        XCTAssertEqual(d.toggles, 0, "a scrub-and-lift must not be read as a play/pause tap")
        XCTAssertEqual(d.seeks, [1])
    }

    // MARK: - Relative +1 → action menu; ≥4 → dismiss

    func test_relativePlusOne_raisesActionMenu() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // baseline 2
        feed(rec, x: 0.50, y: 0.50, fingers: 3)    // +1 → action menu
        XCTAssertEqual(d.actionMenus, 1)
        XCTAssertEqual(d.dismisses, 0)
    }

    func test_fourFingers_dismiss() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // baseline 2
        feed(rec, x: 0.50, y: 0.50, fingers: 4)    // ≥4 → dismiss
        XCTAssertEqual(d.dismisses, 1)
        XCTAssertEqual(d.actionMenus, 0)
    }

    // MARK: - Count-change emits no phantom transport intent

    func test_countChange_emitsNoPhantomStep() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        feed(rec, x: 0.20, y: 0.50, fingers: 2)    // seed at 2
        feed(rec, x: 0.40, y: 0.70, fingers: 3)    // a finger lands AND the centroid jumps far
        XCTAssertTrue(d.seeks.isEmpty, "a contact-count change must not emit a phantom seek")
        XCTAssertTrue(d.volumes.isEmpty, "nor a phantom volume step")
        XCTAssertEqual(d.actionMenus, 1, "only the +1 action-menu intent fires on the rise")
    }

    // MARK: - Menu-open: a lift selects the highlighted row

    func test_menuOpen_liftSelects() {
        let (rec, d) = makePlayerRecognizer(makeSettings())
        rec.playerMenuOpen = true                  // controller opened the action menu
        feed(rec, x: 0.50, y: 0.50, fingers: 2)    // seed
        feed(rec, x: 0.50, y: 0.56, fingers: 2)    // scrub a menu row (vertical)
        feed(rec, x: 0.50, y: 0.56, fingers: 0)    // lift → select (not a toggle)
        XCTAssertEqual(d.selects, 1)
        XCTAssertEqual(d.toggles, 0, "while the menu is open a lift selects, never toggles")
    }
}
