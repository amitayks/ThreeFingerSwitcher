import Foundation

/// Arrow-key direction while the ⌘-Tab switcher is open (Windows-Alt-Tab-style navigation). Left/Right
/// step through windows (mirroring Shift+Tab / Tab, flowing across Spaces); Up/Down navigate the grid's
/// visual rows with positional landing, switching Space only at the grid's top/bottom edge.
enum SwitcherArrow { case left, right, up, down }

/// The pure decision surface the keyboard tap drives. `KeyboardSwitcher` is the production
/// implementation; the tap holds this seam so the tap's event decoding and the session logic stay
/// separable, and the state machine can be unit-tested with no CGEvent/AppKit.
@MainActor
protocol KeyboardSwitcherInput: AnyObject {
    func commandDown()
    func commandUp()
    func tab(shift: Bool)
    func arrow(_ key: SwitcherArrow)
    func escape()
    /// True while a switcher session is open (so the tap consumes Esc / arrows only then).
    var isActive: Bool { get }
}

/// Intents the ⌘-Tab driver emits. The coordinator owns the overlay/model and the cross-Space raise;
/// this driver owns only WHEN to open / step / commit — the keyboard sibling of `GestureRecognizer`.
@MainActor
protocol KeyboardSwitcherDelegate: AnyObject {
    /// First Tab while ⌘ is held: open the switcher on the session origin. Returns whether it actually
    /// opened — `false` when another driver owns the overlay or onboarding owns the stage. A refusal
    /// keeps the session armed so a later Tab retries, rather than stranding a phantom "active" state.
    func keyboardSwitcherOpen() -> Bool
    /// A subsequent Tab (forward) or Shift+Tab (backward): step the selection one window along the flat
    /// reel order, flowing across Spaces in that direction.
    func keyboardSwitcherStep(forward: Bool)
    /// An Up/Down arrow while active: step the selection vertically through the grid's visual rows
    /// exactly as the trackpad's vertical scrub does (positional landing; a Space switch only when the
    /// step crosses the grid's top/bottom edge).
    func keyboardSwitcherStepSpace(up: Bool)
    /// ⌘ released while active: commit — raise the highlighted window, crossing Space if needed.
    func keyboardSwitcherCommit()
    /// Esc while active, or an external teardown: dismiss without raising.
    func keyboardSwitcherCancel()
}

/// Keyboard (⌘-Tab) driver for the window switcher: a pure state machine translating ⌘-down / Tab /
/// Shift+Tab / ⌘-up / Esc into open / step / first / commit / cancel intents (design D4). No AppKit,
/// no CGEvent — the tap decodes events and calls in here; the coordinator renders and raises.
///
///   idle ──(⌘ down)──▶ armed ──(Tab)──▶ active ──(Tab)──▶ active      step forward
///                        │                 │  ──(Shift+Tab)──▶ active  jump to first
///                        │                 │  ──(⌘ up)──▶ commit ─▶ idle
///                        │                 │  ──(Esc)──▶ cancel ─▶ idle
///                        └──(⌘ up, no Tab)─┴──────────────────────▶ idle   (never opened)
@MainActor
final class KeyboardSwitcher: KeyboardSwitcherInput {
    enum Phase: Equatable { case idle, armed, active }
    private(set) var phase: Phase = .idle
    weak var delegate: KeyboardSwitcherDelegate?

    var isActive: Bool { phase == .active }

    /// ⌘ engaged: arm the session so the next Tab opens. We cannot tell ⌘-Tab from ⌘-Q here, so arming
    /// only WATCHES for a Tab — it opens nothing on its own.
    func commandDown() {
        if phase == .idle { phase = .armed }
    }

    /// ⌘ released: commit an open session; a merely-armed session (⌘ held with no Tab) collapses with
    /// no intent — ⌘ alone never opened anything.
    func commandUp() {
        switch phase {
        case .active:
            phase = .idle
            delegate?.keyboardSwitcherCommit()
        case .armed:
            phase = .idle
        case .idle:
            break
        }
    }

    /// A Tab keyDown while ⌘ is held (the tap only forwards it then). The FIRST Tab opens the switcher
    /// AND immediately steps once in its direction (⌘-Tab → next window, ⌘-Shift-Tab → previous), so a
    /// quick press-and-release lands on the adjacent window like the native switcher — rather than merely
    /// highlighting the current one. Subsequent Tabs keep stepping (Tab forward / Shift+Tab backward),
    /// both flowing across Spaces.
    func tab(shift: Bool) {
        switch phase {
        case .idle:
            break   // defensive: a ⌘-held Tab implies armed/active (commandDown precedes it)
        case .armed:
            if delegate?.keyboardSwitcherOpen() == true {
                phase = .active
                delegate?.keyboardSwitcherStep(forward: !shift)   // first Tab advances immediately
            }           // refused (another owner / onboarding): stay armed; a later Tab retries
        case .active:
            delegate?.keyboardSwitcherStep(forward: !shift)
        }
    }

    /// Arrow-key navigation while the switcher is open (⌘ held): Left/Right step backward/forward through
    /// windows (like Shift+Tab / Tab, flowing across Spaces); Up/Down step the grid's visual rows (Space
    /// switch only at the grid edge). Ignored unless a
    /// session is active — arrows never OPEN the switcher (and the tap only forwards them while active).
    func arrow(_ key: SwitcherArrow) {
        guard phase == .active else { return }
        switch key {
        case .right: delegate?.keyboardSwitcherStep(forward: true)
        case .left:  delegate?.keyboardSwitcherStep(forward: false)
        case .up:    delegate?.keyboardSwitcherStepSpace(up: true)
        case .down:  delegate?.keyboardSwitcherStepSpace(up: false)
        }
    }

    /// Esc while active: cancel. Ignored when not active (a bare/armed Esc is left to the focused app).
    func escape() {
        guard phase == .active else { return }
        phase = .idle
        delegate?.keyboardSwitcherCancel()
    }

    /// External teardown (app disabled / resigned active / slept, tap stopped): cancel an open session,
    /// reset an armed one — so a session is never stranded open after its input goes away.
    func forceCancel() {
        switch phase {
        case .active:
            phase = .idle
            delegate?.keyboardSwitcherCancel()
        case .armed:
            phase = .idle
        case .idle:
            break
        }
    }
}
