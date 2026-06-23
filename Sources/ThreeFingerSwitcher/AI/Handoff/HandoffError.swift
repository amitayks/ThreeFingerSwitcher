import Foundation

/// The handoff-specific error taxonomy (`ai-claude-handoff`, design Decision 10) — a clean
/// `LocalizedError` for ONLY the cases `RuntimeError`/`TaskError`/`ClaudeLaunchError` cannot carry.
/// Every case has a per-case, user-facing headline (never a reflected enum dump or raw OS text); raw
/// vendor/OS text rides ONLY in `details` / logs. The production launcher maps `ClaudeLaunchError` into
/// `.launchFailed` at the launch boundary so Core stays consistent and the existing clean headline flows
/// through. `AIError.message(for:)` is extended (THE one translator) to render this taxonomy identically
/// on every surface. MLX-free Core.
enum HandoffError: Error, Equatable {
    /// The skill carries a handoff config but it is turned off (or the global budget is disabled).
    case disabled
    /// Over the daily cap AND parked with no one to confirm — escalated to needs-you, never auto-run.
    case overBudgetNoUser
    /// No folder in the route AND no default working directory — nothing to open Claude in.
    case missingFolder
    /// The launch itself failed; wraps a mapped `ClaudeLaunchError`. `details` is opt-in copyable text.
    case launchFailed(headline: String, details: String?)
}

extension HandoffError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Claude handoff is turned off for this skill."
        case .overBudgetNoUser:
            return "The daily Claude handoff limit was reached. Return to approve this one."
        case .missingFolder:
            return "No folder to open Claude in. Pick a folder and try again."
        case let .launchFailed(headline, _):
            return headline
        }
    }

    /// The opt-in copyable detail (raw error text captured at the boundary), for a "Show details / Copy"
    /// disclosure and logs only. `nil` when the headline already says everything.
    var copyableDetails: String? {
        switch self {
        case .disabled, .overBudgetNoUser, .missingFolder:
            return nil
        case let .launchFailed(_, details):
            return details
        }
    }
}
