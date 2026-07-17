import Foundation

/// The two-lane compute model (addendum §A1 — OWNED by `ai-compute-tiers`, written verbatim from the
/// pinned sketch). MLX-free Core: pure value types + a pure policy, `swift test`-verified.
///
/// The V2 batched runtime (`ai-batched-runtime-and-context`) folds K conversation streams into ONE GPU
/// forward pass per decode step — the right answer for concurrency over one weight read, but single-lane:
/// the foreground reply, the router's `structured()` turn, every classify, every memory-TOC retrieval,
/// and every parked-subagent advance all queue behind the SAME GPU decode loop and the same ~153 GB/s
/// unified-memory bus. This slice adds a SECOND physical lane so the light, frequent, structured work
/// runs OFF the GPU, CONCURRENTLY with the heavy reply, on a small ternary/BitNet-class model whose
/// weights are ~32× smaller and therefore barely touch the shared bus.
///
/// The physics this rests on (cited honestly; only the user's stable-signed build verifies live):
///  - **Prefill ≈ ~4× on the GPU neural accelerators** → prefill-heavy heavy generation + media diffusion
///    belong on the GPU.
///  - **Token-gen is bandwidth-bound at ~153 GB/s** → two heavy generations on one lane contend for one bus.
///  - **Ternary weights ≈ ~32× smaller** → a CPU-lane ternary decode runs concurrently with a GPU
///    generation with low bus contention (the whole reason a second lane is a win, not just a second queue).
///  - **CPU per-token is slower (the honest limit)** → the CPU lane is for SHORT structured bursts ONLY,
///    NEVER the long foreground reply.

// MARK: - Compute lane

/// Which physical lane a runtime / work-unit uses. The GPU does heavy generation + diffusion; the CPU
/// ternary lane does short/frequent/structured work (routing, classify, memory-index, parked subagents)
/// — concurrently, because ternary weights are bandwidth-frugal.
public enum ComputeLane: String, Codable, Sendable, CaseIterable {
    case gpu
    case cpuTernary
}

// MARK: - Agent work role

/// What KIND of agent work a unit is — the input to the role→lane policy. The lane is a deterministic
/// function of the role alone (never the model), so lane assignment can never drift between call sites.
public enum AgentWorkRole: String, Codable, Sendable, CaseIterable {
    /// The main, visible reply → GPU (long, prefill-heavy; the user is watching it).
    case foregroundGeneration
    /// Image/video diffusion → GPU (evicts chat under the 48 GB budget; see the fleet slice §C1).
    case mediaDiffusion
    /// The router's `structured()` route turn → CPU ternary (short, frequent, bounded).
    case toolRoute
    /// Cheap decisions — should-park / needs-you / which-skill → CPU ternary.
    case classify
    /// Memory index/TOC retrieval → CPU ternary.
    case memoryRetrieval
    /// A background advance of a parked session → CPU ternary (runs while the GPU streams the foreground).
    case parkedSubagent
}

// MARK: - Role→lane policy

/// The pure role→lane policy seam (addendum §A1, OWNED here). A total function: every defined role maps
/// to a lane, and the same role always maps to the same lane. This is the SINGLE source of truth every
/// consumer (scheduler, batched runtime, executor) reads — so lane assignment cannot drift between sites.
public protocol LaneRouting: Sendable {
    func lane(for role: AgentWorkRole) -> ComputeLane
}

/// The concrete, default role→lane map (design D1). Heavy generation → `.gpu`; the router turn,
/// classification, memory retrieval, and parked-subagent advances → `.cpuTernary`. No state, no time
/// input needed — a pure switch, trivially `swift test`-exhaustive (one assertion per case).
///
/// Rationale (D1): a pure total map is the one source of truth; deriving the lane from the model
/// descriptor instead would be wrong because the SAME ternary model could in principle serve a GPU role
/// — so the ROLE, not the model, drives the lane.
public struct DefaultLaneRouting: LaneRouting {
    public init() {}

    public func lane(for role: AgentWorkRole) -> ComputeLane {
        switch role {
        case .foregroundGeneration, .mediaDiffusion:
            // Heavy, prefill-bound work → the GPU neural accelerators (~4× prefill).
            return .gpu
        case .toolRoute, .classify, .memoryRetrieval, .parkedSubagent:
            // Short, frequent, structured bursts → the bandwidth-frugal CPU ternary lane.
            return .cpuTernary
        }
    }
}

// MARK: - Lane affinity hint

/// The lane-affinity hint (design D4): the compute lane a runnable session PREFERS, derived from its
/// work role via the role→lane policy. Carried ADDITIVELY beside the parked scheduler's
/// `runnableSessions(now:maxSlots:)` returned IDs and read by the dispatcher — the pinned scheduler /
/// batched-runtime signatures are UNCHANGED; this is an attached value, not a signature change.
///
/// Consumes `AgentSessionID` verbatim from `ai-conversation-runtime` (never redefined).
public struct LaneAffinity: Equatable, Sendable {
    public let sessionID: AgentSessionID
    public let lane: ComputeLane

    public init(sessionID: AgentSessionID, lane: ComputeLane) {
        self.sessionID = sessionID
        self.lane = lane
    }

    /// Derive a session's affinity from its work role via a `LaneRouting` policy. A `parkedSubagent`
    /// session yields `.cpuTernary`; a `foregroundGeneration` session yields `.gpu`.
    public init(sessionID: AgentSessionID, role: AgentWorkRole, routing: LaneRouting) {
        self.init(sessionID: sessionID, lane: routing.lane(for: role))
    }
}
