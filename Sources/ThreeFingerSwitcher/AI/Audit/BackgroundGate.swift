import Foundation

/// The per-step auto-vs-escalate decision (`ai-background-autonomy`, design Decision 6). Pure: a function
/// of the step's EFFECTIVE tier and the session's `ParkState` (CONSUMED verbatim from
/// `ai-parked-sessions`). The wiring (App/integration) computes the effective tier (`BackgroundPolicyResolver`),
/// calls `BackgroundGate.decide`, then runs/escalates/waits and records an `AuditRecord`. MLX-free Core.
public enum BackgroundDecision: Equatable, Sendable {
    /// Run now, in the background, then audit.
    case auto
    /// `.confirm` while parked: stay parked, resolve on restore via the routing approval gate
    /// (DOWN=approve / RIGHT=skip) — no escalation, no glow.
    case waitParked
    /// `.dangerous` while parked: → `ParkScheduler.escalate` → `.needsYou` + badge + notch glow.
    case escalate(reason: String)
    /// The session is active (foreground): the existing routing approval gate owns it (this slice no-ops).
    case foreground
}

/// The pure auto-vs-escalate brain.
public enum BackgroundGate {

    /// The decision table (design Decision 6):
    ///
    /// | effectiveTier | parkState | → BackgroundDecision |
    /// |---|---|---|
    /// | `.auto` | `.parked`/`.idle`/`.active` | `.auto` |
    /// | `.confirm` | `.parked`/`.idle` | `.waitParked` |
    /// | `.confirm` | `.active` | `.foreground` |
    /// | `.dangerous` | `.parked`/`.idle` | `.escalate(reason)` |
    /// | `.dangerous` | `.active` | `.foreground` (already in front; the gate owns it, no glow) |
    /// | any | `.needsYou` | `.waitParked` (already escalated; do not double-escalate) |
    public static func decide(effectiveTier: WritePolicyTier,
                              parkState: ParkState,
                              tool: String = "") -> BackgroundDecision {
        // Already escalated → never double-escalate; the step is recorded awaiting approval and waits.
        if parkState == .needsYou { return .waitParked }

        switch effectiveTier {
        case .auto:
            // A foreground auto-run still runs + audits; the background path is the point.
            return .auto
        case .confirm:
            switch parkState {
            case .active:                          return .foreground
            case .parked, .idle:                   return .waitParked
            case .needsYou:                        return .waitParked   // handled above; exhaustive for the compiler
            }
        case .dangerous:
            switch parkState {
            case .active:                          return .foreground   // already in front; the canvas gate owns it
            case .parked, .idle:                   return .escalate(reason: escalationReason(tool: tool))
            case .needsYou:                        return .waitParked    // handled above
            }
        }
    }

    /// A clean, headline-grade one-liner for the needs-you reason (never raw error text). The glow itself
    /// is rendered by `ai-parked-sessions`.
    public static func escalationReason(tool: String) -> String {
        let name = tool.isEmpty ? "An action" : "\u{201C}\(tool)\u{201D}"
        return "\(name) needs your approval before it can run."
    }
}
