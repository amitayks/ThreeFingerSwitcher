import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for `KeyboardSwitcher` (Sources/ThreeFingerSwitcher/Gesture/KeyboardSwitcher.swift) —
/// the pure ⌘-Tab state machine. Driven directly with a recording delegate (no CGEvent/AppKit); the
/// tap's event decoding and the coordinator's overlay/raise are out of scope here.
@MainActor
final class KeyboardSwitcherTests: XCTestCase {

    /// Records the intents the machine emits; `openResult` simulates the coordinator allowing or
    /// refusing an open (e.g. a trackpad gesture already owns the overlay).
    private final class MockDelegate: KeyboardSwitcherDelegate {
        enum Event: Equatable { case open, step(Bool), space(Bool), commit, cancel }
        var events: [Event] = []
        var openResult = true

        func keyboardSwitcherOpen() -> Bool { events.append(.open); return openResult }
        func keyboardSwitcherStep(forward: Bool) { events.append(.step(forward)) }
        func keyboardSwitcherStepSpace(up: Bool) { events.append(.space(up)) }
        func keyboardSwitcherCommit() { events.append(.commit) }
        func keyboardSwitcherCancel() { events.append(.cancel) }
    }

    private func make() -> (KeyboardSwitcher, MockDelegate) {
        let sw = KeyboardSwitcher()
        let delegate = MockDelegate()
        sw.delegate = delegate
        return (sw, delegate)
    }

    // MARK: - Opening

    func testFirstTabOpensAndAdvances() {
        let (sw, d) = make()
        sw.commandDown()
        XCTAssertEqual(sw.phase, .armed)
        sw.tab(shift: false)
        XCTAssertEqual(sw.phase, .active)
        XCTAssertEqual(d.events, [.open, .step(true)])   // opens AND steps forward immediately
    }

    func testCommandAloneOpensNothing() {
        let (sw, d) = make()
        sw.commandDown()
        sw.commandUp()                       // ⌘ pressed and released with no Tab
        XCTAssertEqual(sw.phase, .idle)
        XCTAssertEqual(d.events, [])         // no open, no commit, no cancel
    }

    func testFirstShiftTabOpensAndStepsBackward() {
        let (sw, d) = make()
        sw.commandDown()
        sw.tab(shift: true)                  // opening ⌘-Shift-Tab: open AND step backward immediately
        XCTAssertEqual(sw.phase, .active)
        XCTAssertEqual(d.events, [.open, .step(false)])
    }

    // MARK: - Stepping

    func testSubsequentTabStepsForward() {
        let (sw, d) = make()
        sw.commandDown()
        sw.tab(shift: false)                 // open + step forward
        sw.tab(shift: false)                 // step forward
        sw.tab(shift: false)                 // step forward
        XCTAssertEqual(d.events, [.open, .step(true), .step(true), .step(true)])
    }

    func testShiftTabStepsBackward() {
        let (sw, d) = make()
        sw.commandDown()
        sw.tab(shift: false)                 // open + step forward
        sw.tab(shift: false)                 // step forward
        sw.tab(shift: true)                  // Shift+Tab → step backward
        XCTAssertEqual(d.events, [.open, .step(true), .step(true), .step(false)])
    }

    // MARK: - Arrow-key navigation (while active)

    func testArrowsNavigateWhileActive() {
        let (sw, d) = make()
        sw.commandDown()
        sw.tab(shift: false)     // open + step forward
        sw.arrow(.right)         // → step forward
        sw.arrow(.left)          // → step backward
        sw.arrow(.up)            // → Space up
        sw.arrow(.down)          // → Space down
        XCTAssertEqual(d.events, [.open, .step(true), .step(true), .step(false), .space(true), .space(false)])
    }

    func testArrowsIgnoredWhileArmed() {
        let (sw, d) = make()
        sw.commandDown()         // armed, not active (no Tab yet)
        sw.arrow(.right)
        sw.arrow(.up)
        XCTAssertEqual(sw.phase, .armed)
        XCTAssertEqual(d.events, [])   // arrows never open the switcher
    }

    func testArrowsIgnoredWhenIdle() {
        let (sw, d) = make()
        sw.arrow(.left)
        sw.arrow(.down)
        XCTAssertEqual(sw.phase, .idle)
        XCTAssertEqual(d.events, [])
    }

    // MARK: - Ending

    func testCommandUpCommitsAnActiveSession() {
        let (sw, d) = make()
        sw.commandDown()
        sw.tab(shift: false)
        sw.commandUp()
        XCTAssertEqual(sw.phase, .idle)
        XCTAssertEqual(d.events, [.open, .step(true), .commit])
    }

    func testEscapeCancelsAnActiveSession() {
        let (sw, d) = make()
        sw.commandDown()
        sw.tab(shift: false)
        sw.escape()
        XCTAssertEqual(sw.phase, .idle)
        XCTAssertEqual(d.events, [.open, .step(true), .cancel])
        // A trailing ⌘-up after Esc must NOT also commit.
        sw.commandUp()
        XCTAssertEqual(d.events, [.open, .step(true), .cancel])
    }

    func testEscapeWhileArmedIsIgnored() {
        let (sw, d) = make()
        sw.commandDown()
        sw.escape()                          // Esc with ⌘ held but nothing opened yet
        XCTAssertEqual(sw.phase, .armed)
        XCTAssertEqual(d.events, [])
    }

    func testForceCancelTearsDownActiveSession() {
        let (sw, d) = make()
        sw.commandDown()
        sw.tab(shift: false)
        sw.forceCancel()
        XCTAssertEqual(sw.phase, .idle)
        XCTAssertEqual(d.events, [.open, .step(true), .cancel])
    }

    func testForceCancelWhileArmedEmitsNothing() {
        let (sw, d) = make()
        sw.commandDown()
        sw.forceCancel()
        XCTAssertEqual(sw.phase, .idle)
        XCTAssertEqual(d.events, [])
    }

    // MARK: - Mutual exclusion (open refused → armed, retries)

    func testRefusedOpenStaysArmedAndRetries() {
        let (sw, d) = make()
        d.openResult = false                 // e.g. a trackpad gesture currently owns the overlay
        sw.commandDown()
        sw.tab(shift: false)                 // open attempted, refused
        XCTAssertEqual(sw.phase, .armed)     // stays armed, not active
        XCTAssertEqual(d.events, [.open])

        d.openResult = true                  // trackpad released — a later Tab reopens
        sw.tab(shift: false)
        XCTAssertEqual(sw.phase, .active)
        XCTAssertEqual(d.events, [.open, .open, .step(true)])   // the successful open advances too
    }

    func testRefusedSessionEmitsNoCommitOnCommandUp() {
        let (sw, d) = make()
        d.openResult = false
        sw.commandDown()
        sw.tab(shift: false)                 // refused → still armed
        sw.commandUp()                       // ⌘ released
        XCTAssertEqual(sw.phase, .idle)
        XCTAssertEqual(d.events, [.open])    // no commit — nothing was ever active
    }
}
