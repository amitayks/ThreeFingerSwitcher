import Foundation

/// Cross-lane concurrency admission (design D3). PURE and deterministic: `now:` and free memory are
/// INPUTS (mirrors `DockHoverModel` / `ConcurrencyBudget`), so the decision is `swift test`-able without
/// real GPU work. The arbiter admits CPU-lane work CONCURRENTLY with GPU work, bounds CPU-lane
/// concurrency on its OWN small cap (it does NOT borrow GPU batch slots), and enforces two honest
/// invariants:
///   1. A heavy GPU generation is NEVER made to wait on CPU-lane work.
///   2. CPU-lane bursts NEVER preempt or starve the foreground GPU reply.
///
/// The two lanes are physically independent (GPU cores + accelerators vs CPU cores); the ternary
/// weights' tiny bandwidth footprint is exactly what makes true concurrency — not a second queue —
/// correct. A CPU-lane unit that cannot be admitted under its own cap or the residency budget in a given
/// step WAITS (stays runnable) — it is NOT a failure.
public struct LaneArbiter: Sendable {

    /// The CPU lane's OWN concurrency cap — small and fixed, independent of the GPU's RAM-derived K.
    /// The CPU lane never borrows GPU batch slots, so this cap is the only bound on CPU-lane concurrency.
    public let cpuLaneCap: Int

    /// The co-residency budget the ternary model must satisfy to be admitted at all.
    public let budget: LaneResidencyBudget

    public init(cpuLaneCap: Int, budget: LaneResidencyBudget) {
        self.cpuLaneCap = max(0, cpuLaneCap)
        self.budget = budget
    }

    /// The outcome of an admission tick — explicit, so a test can assert the two invariants directly.
    public struct Admission: Equatable, Sendable {
        /// GPU-lane requests admitted THIS tick. A heavy GPU generation is ALWAYS admitted (invariant 1):
        /// it never waits on CPU-lane work and is never deferred behind it.
        public var admittedGPU: [AgentSessionID]
        /// CPU-lane requests admitted THIS tick, bounded by `cpuLaneCap` + the residency budget.
        public var admittedCPU: [AgentSessionID]
        /// CPU-lane requests that could not be admitted this tick — they WAIT (stay runnable), not fail.
        public var waitingCPU: [AgentSessionID]

        public init(admittedGPU: [AgentSessionID] = [],
                    admittedCPU: [AgentSessionID] = [],
                    waitingCPU: [AgentSessionID] = []) {
            self.admittedGPU = admittedGPU
            self.admittedCPU = admittedCPU
            self.waitingCPU = waitingCPU
        }
    }

    /// Admit GPU-lane and CPU-lane requests for one tick, given the free memory, current GPU stream
    /// count, context length, and `now` (accepted for deterministic-input parity; admission here depends
    /// only on the lane state + budget, not on wall-clock — but the signature mirrors the project's
    /// `now:`-injected pure models so a later cadence rule slots in without a signature break).
    ///
    /// - `gpuRequests`: GPU-affined + foreground sessions wanting to advance.
    /// - `cpuRequests`: CPU-ternary-affined sessions (router turns, classify, memory, parked subagents).
    /// - `inflightCPU`: CPU-lane units ALREADY running this step (counted against `cpuLaneCap`).
    public func admit(now: Date,
                      freeBytes: Int64,
                      gpuStreams: Int,
                      contextTokens: Int,
                      gpuRequests: [AgentSessionID],
                      cpuRequests: [AgentSessionID],
                      inflightCPU: Int = 0) -> Admission {
        _ = now

        // Invariant 1: the GPU lane is admitted IN FULL, unconditionally — it never waits on CPU work.
        // The GPU lane's own concurrency (K) is bounded upstream by `ConcurrencyBudget`/the batched
        // runtime; the arbiter never defers a GPU request behind CPU-lane work.
        var result = Admission(admittedGPU: gpuRequests)

        // The CPU lane co-resides only if the small ternary footprint fits beside the GPU batch + KV.
        // If it cannot co-reside, every CPU burst WAITS (not fails) — invariant: unadmittable ⇒ wait.
        let coResides = budget.ternaryCoResides(freeBytes: freeBytes,
                                                gpuStreams: gpuStreams,
                                                contextTokens: contextTokens)
        guard coResides else {
            result.waitingCPU = cpuRequests
            return result
        }

        // Bound CPU-lane concurrency on its OWN cap (invariant 2: it never borrows GPU slots, so even a
        // flood of CPU bursts cannot grow past `cpuLaneCap` and cannot touch the foreground GPU reply).
        let availableCPU = max(0, cpuLaneCap - max(0, inflightCPU))
        if cpuRequests.count <= availableCPU {
            result.admittedCPU = cpuRequests
        } else {
            result.admittedCPU = Array(cpuRequests.prefix(availableCPU))
            result.waitingCPU = Array(cpuRequests.dropFirst(availableCPU))
        }
        return result
    }
}
