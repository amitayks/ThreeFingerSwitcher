import AppKit

/// The dwell-to-arm timing nucleus, shared by the launcher overlay (charge the selected item, then
/// arm) and the First Touch wizard's hold-to-continue affordance — one implementation so the charge
/// the tutorial teaches can never drift from the charge the product performs.
@MainActor
final class DwellArmDriver {
    private var work: DispatchWorkItem?

    /// Begin (or restart) a charge: `onArmed` fires after `dwell` seconds unless cancelled.
    func charge(after dwell: Double, onArmed: @escaping @MainActor () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { onArmed() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: item)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    /// The arm haptic: a single best-effort `.alignment` tick — the product's only haptic pattern,
    /// reserved for moments of arrival (an item arming, a wizard step completing).
    static func hapticTick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
