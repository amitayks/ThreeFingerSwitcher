import XCTest
@testable import ThreeFingerSwitcherCore

/// The AI-canvas resolve interpretation is a pure helper (`AppCoordinator.canvasResolveDecision`) so it
/// can be asserted without standing up the whole coordinator. The recognizer has already axis-locked, so
/// exactly one of `dx`/`dy` is non-zero, with the fixed sign convention `dy<0 → swipeDown`,
/// `dy>0 → swipeUp`, `dx<0 → swipeLeft`, `dx>0 → swipeRight` (`add-gesture-previews-and-bindings` §9.3).
///
/// These cover: the default binding reproduces today's grammar (down=commit, up=ignore, both horizontals
/// discard), and a remap (assigning swipe-right to commit) moves commit to the new excursion while the
/// previously-default excursion no longer commits. The `canvasAtTop` commit guard lives at the call site
/// (binding-independent) and is verified in the coordinator-level integration, not here.
@MainActor
final class CanvasResolveBindingTests: XCTestCase {

    private func decide(_ dx: Int, _ dy: Int, _ binding: GestureBindings.CanvasBinding)
        -> AppCoordinator.CanvasResolveDecision {
        AppCoordinator.canvasResolveDecision(dx: dx, dy: dy, binding: binding)
    }

    // MARK: - Default binding reproduces today's grammar

    /// Default (commit=down, dismiss=left, ignore=up, spare=right): down = commit, up = ignore, BOTH
    /// horizontals discard (left is bound to dismiss; right is the spare horizontal → also discards).
    func test_defaultBinding_reproducesTodaysGrammar() {
        let c = GestureBindings.CanvasBinding.default
        XCTAssertEqual(decide(0, -1, c), .commit,  "down = commit")
        XCTAssertEqual(decide(0,  1, c), .ignore,  "up = ignore")
        XCTAssertEqual(decide(-1, 0, c), .discard, "left = dismiss")
        XCTAssertEqual(decide( 1, 0, c), .discard, "right (spare horizontal) also discards")
    }

    // MARK: - Remap: commit follows the binding; the old default no longer commits

    /// After binding commit to swipe-right, a right excursion commits and a down excursion no longer
    /// commits (down inherits dismiss's old excursion via the swap → discard).
    func test_remapCommitToSwipeRight_rightCommits_downNoLongerCommits() {
        // Default has dismiss=left, ignore=up, commit=down, right=spare. Assigning right→commit swaps
        // right with whichever action holds it — none does (right is spare) — so commit just moves to
        // right and down becomes the spare.
        let c = GestureBindings.CanvasBinding.default.assigning(.swipeRight, to: .commit)
        XCTAssertEqual(c.commit, .swipeRight)

        XCTAssertEqual(decide(1, 0, c), .commit, "right now commits")
        XCTAssertNotEqual(decide(0, -1, c), .commit, "down no longer commits")
        // Down is now the spare VERTICAL excursion → ignored (not a horizontal, so not a discard).
        XCTAssertEqual(decide(0, -1, c), .ignore, "the freed down excursion (vertical spare) is ignored")
        // Up is still bound to ignore.
        XCTAssertEqual(decide(0, 1, c), .ignore, "up stays ignore")
        // Left is still bound to dismiss.
        XCTAssertEqual(decide(-1, 0, c), .discard, "left stays dismiss")
    }

    /// A remap that swaps two bound actions: assign swipe-left (held by dismiss) to commit. The swap gives
    /// dismiss the excursion commit used to hold (down). So left commits, down discards, up ignores.
    func test_remapSwapsCommitAndDismiss() {
        let c = GestureBindings.CanvasBinding.default.assigning(.swipeLeft, to: .commit)
        XCTAssertEqual(c.commit, .swipeLeft)
        XCTAssertEqual(c.dismiss, .swipeDown, "dismiss inherited commit's old excursion")

        XCTAssertEqual(decide(-1, 0, c), .commit,  "left now commits")
        XCTAssertEqual(decide(0, -1, c), .discard, "down now dismisses")
        XCTAssertEqual(decide(0,  1, c), .ignore,  "up stays ignore")
        // Right is the spare horizontal → discard.
        XCTAssertEqual(decide(1, 0, c), .discard, "right (spare horizontal) discards")
    }

    // MARK: - Spare-excursion fallback is axis-aware

    /// With a binding whose spare excursion is VERTICAL, the spare is ignored (only a horizontal spare
    /// discards). Bind ignore to swipe-right so the spare becomes swipe-up (vertical).
    func test_verticalSpareIsIgnored_horizontalSpareDiscards() {
        // Default ignore=up. Move ignore to right → up becomes the spare (vertical).
        let c = GestureBindings.CanvasBinding.default.assigning(.swipeRight, to: .ignore)
        XCTAssertEqual(c.ignore, .swipeRight)
        XCTAssertEqual(decide(0, 1, c), .ignore, "the freed up excursion (vertical spare) is ignored")
        XCTAssertEqual(decide(1, 0, c), .ignore, "right is now bound to ignore")
        // Commit/dismiss unchanged.
        XCTAssertEqual(decide(0, -1, c), .commit, "down stays commit")
        XCTAssertEqual(decide(-1, 0, c), .discard, "left stays dismiss")
    }

    /// A zero delta (no excursion) is a no-op (treated as ignore) — defensive; the recognizer never emits it.
    func test_zeroDeltaIsIgnored() {
        XCTAssertEqual(decide(0, 0, .default), .ignore)
    }
}
