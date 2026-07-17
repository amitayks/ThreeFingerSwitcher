import Foundation

/// The fleet-specific error taxonomy (design D7) — a clean `LocalizedError` for ONLY the two cases the
/// shared `RuntimeError` cannot carry. Capability-mismatch, unavailable-hardware, download/integrity
/// failures all stay `RuntimeError`; these two are genuinely fleet-specific:
///  - `.cannotAdmit` — the residency plan is INFEASIBLE (the target does not fit even after evicting every
///    evictable on-device model). The eviction list it tried rides in `evictedDetails` (opt-in copyable),
///    NEVER in the headline (raw interpolation in a headline is banned).
///  - `.cloudDisabled` — a `.cloud` member was selected while `fleetCloudEscalationEnabled` is off.
///
/// Every case has a per-case, user-facing headline; raw lists/text ride ONLY in `details` and logs.
/// `AIError.message(for:)` (THE one translator) renders this taxonomy identically on every surface.
/// A failed admission is an observable `.failed`, never a false "loaded". MLX-free Core.
public enum FleetError: Error, Equatable {
    /// The target could not be admitted under the budget even after evicting everything evictable.
    /// `evictedDetails` is the (opt-in, copyable) list of what the planner tried to evict — kept OUT of
    /// the headline.
    case cannotAdmit(modelName: String, evictedDetails: String? = nil)
    /// A cloud member was selected while cloud escalation is off (`fleetCloudEscalationEnabled` false).
    case cloudDisabled(modelName: String)
}

extension FleetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .cannotAdmit(modelName, _):
            return "Not enough memory to load \(modelName) right now."
        case let .cloudDisabled(modelName):
            return "\(modelName) is a cloud model. Turn on cloud escalation to use it."
        }
    }

    /// The opt-in copyable detail (the eviction list the planner tried), for a "Show details / Copy"
    /// disclosure and logs only — never the headline. `nil` when the headline already says everything.
    public var copyableDetails: String? {
        switch self {
        case let .cannotAdmit(_, evictedDetails):
            return evictedDetails
        case .cloudDisabled:
            return nil
        }
    }
}
