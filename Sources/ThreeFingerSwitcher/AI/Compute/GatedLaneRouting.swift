import Foundation

/// The master-toggle gate over the role→lane policy (design D6). A `LaneRouting` DECORATOR: when the
/// CPU lane is disabled, it coerces EVERY role's lane to `.gpu`, so a one-lane / fleet-of-one build
/// stays valid and behaves exactly as today (no `TernaryCPURuntime` installed, all work on the GPU
/// batched runtime). When enabled, it delegates to the wrapped policy (`DefaultLaneRouting`) unchanged.
///
/// The CPU lane is gated by `cpuLaneEnabled`, itself under the master `fullPotentialEnabled` — BOTH owned
/// by `ai-full-potential-toggle` (addendum §D1). This slice READS those flags; it does NOT define the
/// persisted keys. They are injected here as booleans (and recomputed by the owner whenever settings
/// change) so the gate LOGIC is pure and `swift test`-verified without depending on `AppSettings`. The
/// effective gate is `fullPotentialEnabled && cpuLaneEnabled` (a sub-flag never overrides the master OFF).
public struct GatedLaneRouting: LaneRouting {
    /// The policy applied when the CPU lane is enabled (typically `DefaultLaneRouting`).
    private let base: LaneRouting
    /// `fullPotentialEnabled && cpuLaneEnabled` — the two-lane policy is in effect only when true.
    public let cpuLaneActive: Bool

    /// - Parameters:
    ///   - base: the underlying role→lane policy (`DefaultLaneRouting`).
    ///   - fullPotentialEnabled: the master gate (`ai-full-potential-toggle`, §D1 — read, not owned).
    ///   - cpuLaneEnabled: the CPU-lane sub-flag (§D1 — read, not owned).
    public init(base: LaneRouting = DefaultLaneRouting(),
                fullPotentialEnabled: Bool,
                cpuLaneEnabled: Bool) {
        self.base = base
        self.cpuLaneActive = fullPotentialEnabled && cpuLaneEnabled
    }

    public func lane(for role: AgentWorkRole) -> ComputeLane {
        // OFF (master off OR sub-flag off): coerce every role to the GPU lane — the single-lane build.
        guard cpuLaneActive else { return .gpu }
        // ON: the `DefaultLaneRouting` mapping holds (heavy → GPU, structured → CPU ternary).
        return base.lane(for: role)
    }
}
