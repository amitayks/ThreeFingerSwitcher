// LaneDispatch — lane-keyed runtime wiring + additive lane-affinity dispatch (ai-compute-tiers §6).
//
// FLAGGED: user xcodebuild + stable-signed build.
//
// This welds the CPU ternary lane onto the EXISTING seams ADDITIVELY — without editing the sibling
// slices' files:
//   - §6.1 (D2): resolve a runtime BY `ComputeLane` through the existing provisioner/`runtimeFactory`
//     seam. The GPU lane keeps returning `BatchedGemmaMLXRuntime`; the CPU lane returns
//     `TernaryCPURuntime`. NO `ModelManager` API change.
//   - §6.2 (D4): read `ParkScheduler.runnableSessions(now:maxSlots:)`'s returned IDs and ATTACH a
//     `LaneAffinity` per session via an ADDITIVE accessor — the pinned `runnableSessions` signature is
//     UNCHANGED and the `ai-parked-sessions` files are NOT edited.
//   - §6.3 (D4): route `.cpuTernary`-affined sessions to `TernaryCPURuntime` while the GPU
//     `batchStep(...)` keeps serving `.gpu`-affined + foreground sessions — ADDITIVE, the
//     `ai-batched-runtime-and-context` files are NOT edited.
//
// Net effect: a `parkedSubagent` session advances on the CPU lane CONCURRENTLY with a foreground GPU
// generation, instead of waiting for a GPU batch slot. Native-linked (it constructs the MLX GPU runtime
// + the bitnet.cpp-class CPU runtime), so it is `xcodebuild` compile-verify ONLY; the live two-lane
// concurrency is the USER's stable-signed run-verify (task 8.3).
//
// NOTE on the fleet descriptor (addendum §C1, owned by `ai-model-fleet`): the lane-tagged
// `ModelDescriptor.lane`/`ModelRole.ternaryChat` are CONSUMED here, not redefined. Until that slice
// lands, the CPU-lane descriptor is keyed by `ComputeLane.cpuTernary` directly; when the fleet's
// lane-tagged descriptor lands, `runtime(for:)` reads `descriptor.lane` with no call-site change.

import Foundation
import ThreeFingerSwitcherCore

public enum LaneDispatch {

    // MARK: - §7.1 Master-toggle install gate

    /// Whether to INSTALL the CPU ternary lane (design D6 / §7.1): gated on `cpuLaneEnabled` UNDER the
    /// master `fullPotentialEnabled` (addendum §D1, owned by `ai-full-potential-toggle` — read, not
    /// owned). OFF → no `TernaryCPURuntime` is constructed, and the OFF-coercion `GatedLaneRouting`
    /// decorator routes every role to `.gpu`, so the build behaves exactly as a single-lane one (no
    /// regression). The same `fullPotentialEnabled && cpuLaneEnabled` predicate as `GatedLaneRouting`,
    /// kept here as the install-side gate so the runtime is never even allocated when OFF.
    public static func shouldInstallCPULane(fullPotentialEnabled: Bool, cpuLaneEnabled: Bool) -> Bool {
        fullPotentialEnabled && cpuLaneEnabled
    }

    /// FLAGGED: construct the CPU ternary runtime ONLY when the gate is on. Returns `nil` when OFF, so the
    /// dispatch path above runs the GPU lane alone (today's behavior). Native-only (it allocates the
    /// bitnet.cpp-class runtime); the agent compile-verifies the gate, the user run-verifies the install.
    public static func installCPULane(fullPotentialEnabled: Bool,
                                      cpuLaneEnabled: Bool,
                                      weightsURL: URL) -> TernaryCPURuntime? {
        guard shouldInstallCPULane(fullPotentialEnabled: fullPotentialEnabled,
                                   cpuLaneEnabled: cpuLaneEnabled) else { return nil }
        return TernaryCPURuntime(weightsURL: weightsURL)
    }

    // MARK: - §6.1 Lane-keyed runtime resolution (no ModelManager API change)

    /// Resolve the runtime for a `ComputeLane` through the existing provisioner seam (design D2). The
    /// GPU lane is the resident `BatchedGemmaMLXRuntime` (already the provisioner's return); the CPU lane
    /// is a `TernaryCPURuntime` installed ONLY when `cpuLaneActive` (gated upstream, §7). Feature code
    /// never sees these concrete types — it selects BY lane.
    ///
    /// Returns `nil` for `.cpuTernary` when the CPU lane is not installed (OFF), so the caller falls back
    /// to the GPU lane (the OFF-coercion decorator already routes every role to `.gpu`, so this is a
    /// belt-and-braces guard).
    public static func runtime(for lane: ComputeLane,
                               gpu: LLMRuntime,
                               ternary: TernaryCPURuntime?) -> LLMRuntime? {
        switch lane {
        case .gpu:        return gpu
        case .cpuTernary: return ternary
        }
    }

    // MARK: - §6.2 Additive lane-affinity attachment (runnableSessions signature UNCHANGED)

    /// Attach a `LaneAffinity` to each runnable parked session WITHOUT changing `runnableSessions`'s
    /// pinned signature (design D4). The scheduler returns plain `AgentSessionID`s as before; this
    /// additive accessor derives each session's lane from its work role via the `LaneRouting` policy.
    ///
    /// A parked session's work IS a `parkedSubagent` advance → `.cpuTernary` (under the default policy);
    /// when the CPU lane is OFF the injected `routing` is the `GatedLaneRouting` decorator, which coerces
    /// every role to `.gpu`, so the affinity correctly reads `.gpu` and the session stays on the GPU lane.
    public static func affinities(for runnable: [AgentSessionID],
                                  role: AgentWorkRole = .parkedSubagent,
                                  routing: LaneRouting) -> [LaneAffinity] {
        runnable.map { LaneAffinity(sessionID: $0, role: role, routing: routing) }
    }

    // MARK: - §6.3 Additive dispatch split (batchStep + parked files NOT edited)

    /// The result of partitioning a runnable set by lane affinity (design D4) — pure, so the partition
    /// logic is testable; the actual stepping below drives the two lanes.
    public struct LanePartition: Equatable, Sendable {
        /// `.gpu`-affined + foreground sessions → served by the batched GPU `batchStep(...)` (unchanged).
        public var gpu: [AgentSessionID]
        /// `.cpuTernary`-affined sessions → served by `TernaryCPURuntime`, concurrently with the GPU.
        public var cpuTernary: [AgentSessionID]
        public init(gpu: [AgentSessionID] = [], cpuTernary: [AgentSessionID] = []) {
            self.gpu = gpu
            self.cpuTernary = cpuTernary
        }
    }

    /// Split runnable sessions by their attached lane affinity. The foreground session (if any) is always
    /// forced onto the GPU partition (its role is `foregroundGeneration` → `.gpu` by the policy, and the
    /// long reply is GPU-only — D5). Pure + deterministic.
    public static func partition(_ affinities: [LaneAffinity],
                                 foreground: AgentSessionID? = nil) -> LanePartition {
        var p = LanePartition()
        for a in affinities {
            if a.sessionID == foreground { p.gpu.append(a.sessionID); continue }
            switch a.lane {
            case .gpu:        p.gpu.append(a.sessionID)
            case .cpuTernary: p.cpuTernary.append(a.sessionID)
            }
        }
        if let fg = foreground, !p.gpu.contains(fg) { p.gpu.insert(fg, at: 0) }
        return p
    }

    /// FLAGGED: drive both lanes for one dispatch round. The GPU `batchStep(...)` (§3.6, the
    /// `ai-batched-runtime-and-context` runtime) keeps serving the `.gpu` partition + the foreground
    /// session unchanged; the `.cpuTernary` partition advances on `TernaryCPURuntime` CONCURRENTLY (a
    /// separate, independent task tree), bounded by the Core `LaneArbiter`'s CPU cap + co-residency
    /// budget — it never borrows a GPU batch slot. Native-only; the live concurrency is user-run-verify.
    ///
    /// This is ADDITIVE: it CALLS the pinned `batchStep(requests)` with the GPU partition's requests
    /// exactly as today, and runs the CPU partition beside it — neither the batched runtime nor the
    /// parked scheduler is edited.
    @MainActor
    public static func dispatch(partition: LanePartition,
                                requests: [AgentSessionID: LLMChatRequest],
                                gpu: BatchedLLMRuntime,
                                ternary: TernaryCPURuntime?,
                                onToken: @escaping @Sendable (AgentSessionID, Token) -> Void) {
        // GPU lane: the foreground + `.gpu`-affined sessions through the UNCHANGED batched step.
        let gpuRequests = requests.filter { partition.gpu.contains($0.key) }
        if !gpuRequests.isEmpty {
            let stream = gpu.batchStep(gpuRequests)
            Task { @MainActor in
                do {
                    for try await (id, token) in stream { onToken(id, token) }
                } catch {
                    // A GPU-stream failure stays the batched runtime's concern (one stream's failure does
                    // not abort the batch); surfaced via its own `.failed` path, mapped to RuntimeError.
                    TernaryCPURuntime.log.error("GPU batchStep failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // CPU ternary lane: advance each `.cpuTernary`-affined session CONCURRENTLY (a short burst each).
        // A failed burst is an observable `.failed` for THAT turn (mapped to RuntimeError at the conformer
        // boundary), never a false "done" and never aborting the GPU batch; cancellation is benign.
        guard let ternary else { return }   // CPU lane not installed (OFF) → nothing to do here.
        for id in partition.cpuTernary {
            guard let req = requests[id] else { continue }
            Task { @MainActor in
                do {
                    for try await token in ternary.chat(req) { onToken(id, token) }
                } catch is CancellationError {
                    // Not a failure — the burst was discarded.
                } catch {
                    // The burst's `.failed` is surfaced by the caller's turn state via AIError.message(for:).
                    TernaryCPURuntime.log.error("CPU ternary burst failed for session: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
