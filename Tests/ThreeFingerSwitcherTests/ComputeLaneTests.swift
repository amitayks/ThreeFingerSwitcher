import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the pure-Core substrate of `ai-compute-tiers` (tasks §1–§4, §7): the two-lane model
/// (`ComputeLane`/`AgentWorkRole`), the role→lane policy (`DefaultLaneRouting`), the lane-affinity hint,
/// the co-residency budget + cross-lane arbiter, the OFF-coercion gate decorator, the deterministic
/// `StubTernaryRuntime`, and the error mapping → `RuntimeError`/`AIError.message(for:)`.
///
/// The native-linked `TernaryCPURuntime` (§5), the lane-keyed wiring + additive dispatch (§6), and the
/// live two-lane concurrency (§8.3) are `xcodebuild` compile-verify / user-run-verify only.
final class ComputeLaneTests: XCTestCase {

    // MARK: - §1.1 ComputeLane / AgentWorkRole construct + Codable round-trip

    func testComputeLaneRoundTripsCodable() throws {
        for lane in ComputeLane.allCases {
            let data = try JSONEncoder().encode(lane)
            let back = try JSONDecoder().decode(ComputeLane.self, from: data)
            XCTAssertEqual(lane, back)
        }
        XCTAssertEqual(ComputeLane.allCases.count, 2)
    }

    func testAgentWorkRoleRoundTripsCodable() throws {
        for role in AgentWorkRole.allCases {
            let data = try JSONEncoder().encode(role)
            let back = try JSONDecoder().decode(AgentWorkRole.self, from: data)
            XCTAssertEqual(role, back)
        }
        XCTAssertEqual(AgentWorkRole.allCases.count, 6)
    }

    // MARK: - §1.2 DefaultLaneRouting — exhaustive role→lane (one assertion per case)

    func testDefaultLaneRoutingIsExhaustiveAndTotal() {
        let routing = DefaultLaneRouting()
        XCTAssertEqual(routing.lane(for: .foregroundGeneration), .gpu)
        XCTAssertEqual(routing.lane(for: .mediaDiffusion), .gpu)
        XCTAssertEqual(routing.lane(for: .toolRoute), .cpuTernary)
        XCTAssertEqual(routing.lane(for: .classify), .cpuTernary)
        XCTAssertEqual(routing.lane(for: .memoryRetrieval), .cpuTernary)
        XCTAssertEqual(routing.lane(for: .parkedSubagent), .cpuTernary)
        // Total: every defined role has a lane (the switch above is exhaustive by construction).
        for role in AgentWorkRole.allCases {
            _ = routing.lane(for: role)  // no trap / no default-needed
        }
    }

    func testDefaultLaneRoutingIsDeterministic() {
        let routing = DefaultLaneRouting()
        for role in AgentWorkRole.allCases {
            XCTAssertEqual(routing.lane(for: role), routing.lane(for: role))
        }
    }

    // MARK: - §1.3 LaneAffinity derived from the role

    func testLaneAffinityFollowsWorkRole() {
        let routing = DefaultLaneRouting()
        let parked = AgentSessionID()
        let foreground = AgentSessionID()

        let parkedAffinity = LaneAffinity(sessionID: parked, role: .parkedSubagent, routing: routing)
        XCTAssertEqual(parkedAffinity.lane, .cpuTernary)
        XCTAssertEqual(parkedAffinity.sessionID, parked)

        let fgAffinity = LaneAffinity(sessionID: foreground, role: .foregroundGeneration, routing: routing)
        XCTAssertEqual(fgAffinity.lane, .gpu)
    }

    // MARK: - §2.1 LaneResidencyBudget — ternary co-resides where a 2nd chat model would not

    func testTernaryCoResidesWhereSecondChatModelWouldNot() {
        // ~17 GB chat weights resident; ternary ~32× smaller ≈ 0.53 GB; KV ~0.5 GB/stream.
        let gb: Int64 = 1024 * 1024 * 1024
        let budget = LaneResidencyBudget(
            chatWeightBytes: 17 * gb,
            kvBytesPerGPUStream: gb / 2,
            ternaryResidencyBytes: 17 * gb / 32,    // ~0.53 GB
            reservedBytes: 4 * gb
        )
        // 36 GB of unified memory is committed to the AI feature here (a realistic working budget on a
        // 48 GB machine after the OS + other apps). With chat (17) + 4 streams KV (2) + reserved (4) =
        // 23 GB used, ~13 GB of headroom remains.
        let freeBytes = 36 * gb

        // The small ternary model (~0.53 GB) fits in that ~13 GB headroom and co-resides.
        XCTAssertTrue(budget.ternaryCoResides(freeBytes: freeBytes, gpuStreams: 4, contextTokens: 8192))

        // A SECOND full chat model (17 GB) would NOT fit in that same ~13 GB headroom — the contrast that
        // makes a second LANE a co-resident win rather than an eviction.
        let secondChatBytes = 17 * gb
        let remaining = freeBytes - budget.gpuResidentBytes(gpuStreams: 4) - budget.reservedBytes
        XCTAssertGreaterThanOrEqual(remaining, budget.ternaryResidencyBytes,
                                    "ternary fits in the remaining headroom")
        XCTAssertLessThan(remaining, secondChatBytes,
                          "a second full chat model would NOT fit in that same headroom")
    }

    func testTernaryResidencyBytesTogglesTheBoundary() {
        let gb: Int64 = 1024 * 1024 * 1024
        var budget = LaneResidencyBudget(chatWeightBytes: 17 * gb,
                                         kvBytesPerGPUStream: gb,
                                         ternaryResidencyBytes: gb,   // 1 GB
                                         reservedBytes: 4 * gb)
        // free 48, chat 17, 25 streams * 1 GB = 25, reserved 4 → 25 - 25 - 4 ... tune to a tight boundary.
        let free: Int64 = 23 * gb   // chat 17 + reserved 4 = 21 used at 0 streams → 2 GB remains.
        XCTAssertTrue(budget.ternaryCoResides(freeBytes: free, gpuStreams: 0, contextTokens: 1024),
                      "1 GB ternary fits in 2 GB headroom")
        // Toggle the ternary footprint UP past the headroom → it flips to NOT co-residing.
        budget.ternaryResidencyBytes = 3 * gb
        XCTAssertFalse(budget.ternaryCoResides(freeBytes: free, gpuStreams: 0, contextTokens: 1024),
                       "3 GB ternary does NOT fit in 2 GB headroom")
        // Toggle back DOWN → co-resides again.
        budget.ternaryResidencyBytes = gb / 2
        XCTAssertTrue(budget.ternaryCoResides(freeBytes: free, gpuStreams: 0, contextTokens: 1024))
    }

    // MARK: - §2.2 LaneArbiter — concurrent admit, GPU never waits, CPU cap bounds, waits not fails

    private func ampleBudget() -> LaneResidencyBudget {
        let gb: Int64 = 1024 * 1024 * 1024
        return LaneResidencyBudget(chatWeightBytes: 17 * gb,
                                   kvBytesPerGPUStream: gb / 2,
                                   ternaryResidencyBytes: gb / 2,
                                   reservedBytes: 4 * gb)
    }

    func testArbiterAdmitsGPUAndCPUConcurrentlyInOneTick() {
        let arbiter = LaneArbiter(cpuLaneCap: 2, budget: ampleBudget())
        let gpu = AgentSessionID()
        let cpu = AgentSessionID()
        let result = arbiter.admit(now: Date(),
                                   freeBytes: 48 * 1024 * 1024 * 1024,
                                   gpuStreams: 1,
                                   contextTokens: 8192,
                                   gpuRequests: [gpu],
                                   cpuRequests: [cpu])
        XCTAssertEqual(result.admittedGPU, [gpu])
        XCTAssertEqual(result.admittedCPU, [cpu])
        XCTAssertTrue(result.waitingCPU.isEmpty)
    }

    func testArbiterNeverDefersGPUBehindCPUWork() {
        // Even when CPU work cannot co-reside (tiny free memory), the GPU lane is STILL admitted in full.
        let arbiter = LaneArbiter(cpuLaneCap: 4, budget: ampleBudget())
        let gpu1 = AgentSessionID(); let gpu2 = AgentSessionID()
        let cpu = AgentSessionID()
        let result = arbiter.admit(now: Date(),
                                   freeBytes: 1 * 1024 * 1024 * 1024,   // 1 GB — nothing co-resides
                                   gpuStreams: 1,
                                   contextTokens: 8192,
                                   gpuRequests: [gpu1, gpu2],
                                   cpuRequests: [cpu])
        XCTAssertEqual(result.admittedGPU, [gpu1, gpu2], "GPU never waits on CPU work")
        XCTAssertTrue(result.admittedCPU.isEmpty)
        XCTAssertEqual(result.waitingCPU, [cpu], "the unadmittable CPU burst WAITS, it does not fail")
    }

    func testArbiterCPUCapBoundsAndOverCapWaitsNotFails() {
        let arbiter = LaneArbiter(cpuLaneCap: 2, budget: ampleBudget())
        let a = AgentSessionID(); let b = AgentSessionID(); let c = AgentSessionID()
        let result = arbiter.admit(now: Date(),
                                   freeBytes: 48 * 1024 * 1024 * 1024,
                                   gpuStreams: 2,
                                   contextTokens: 8192,
                                   gpuRequests: [],
                                   cpuRequests: [a, b, c])
        XCTAssertEqual(result.admittedCPU, [a, b], "bounded by the CPU lane's own cap")
        XCTAssertEqual(result.waitingCPU, [c], "the over-cap burst WAITS (not a failure)")
    }

    func testArbiterRespectsInflightCPU() {
        let arbiter = LaneArbiter(cpuLaneCap: 2, budget: ampleBudget())
        let a = AgentSessionID()
        let result = arbiter.admit(now: Date(),
                                   freeBytes: 48 * 1024 * 1024 * 1024,
                                   gpuStreams: 1,
                                   contextTokens: 8192,
                                   gpuRequests: [],
                                   cpuRequests: [a],
                                   inflightCPU: 2)   // cap already full
        XCTAssertTrue(result.admittedCPU.isEmpty)
        XCTAssertEqual(result.waitingCPU, [a])
    }

    func testArbiterIsDeterministicForFixedInputs() {
        let arbiter = LaneArbiter(cpuLaneCap: 3, budget: ampleBudget())
        let now = Date(timeIntervalSince1970: 1_000)
        let gpu = [AgentSessionID()]; let cpu = [AgentSessionID(), AgentSessionID()]
        let r1 = arbiter.admit(now: now, freeBytes: 48 * 1024 * 1024 * 1024, gpuStreams: 1,
                               contextTokens: 4096, gpuRequests: gpu, cpuRequests: cpu)
        let r2 = arbiter.admit(now: now, freeBytes: 48 * 1024 * 1024 * 1024, gpuStreams: 1,
                               contextTokens: 4096, gpuRequests: gpu, cpuRequests: cpu)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - §3.1 GatedLaneRouting OFF-coercion decorator

    func testGateOffCoercesEveryRoleToGPU() {
        let gate = GatedLaneRouting(fullPotentialEnabled: false, cpuLaneEnabled: false)
        for role in AgentWorkRole.allCases {
            XCTAssertEqual(gate.lane(for: role), .gpu, "OFF → every role coerces to .gpu")
        }
        XCTAssertFalse(gate.cpuLaneActive)
    }

    func testGateSubFlagOffStillCoercesToGPU() {
        // Master ON but the CPU-lane sub-flag OFF → still one-lane.
        let gate = GatedLaneRouting(fullPotentialEnabled: true, cpuLaneEnabled: false)
        XCTAssertEqual(gate.lane(for: .toolRoute), .gpu)
        XCTAssertFalse(gate.cpuLaneActive)
    }

    func testGateMasterOffOverridesSubFlagOn() {
        // Sub-flag ON but the MASTER OFF → still one-lane (a sub-flag never overrides the master OFF).
        let gate = GatedLaneRouting(fullPotentialEnabled: false, cpuLaneEnabled: true)
        XCTAssertEqual(gate.lane(for: .classify), .gpu)
        XCTAssertFalse(gate.cpuLaneActive)
    }

    func testGateOnPreservesDefaultMapping() {
        let gate = GatedLaneRouting(fullPotentialEnabled: true, cpuLaneEnabled: true)
        XCTAssertTrue(gate.cpuLaneActive)
        XCTAssertEqual(gate.lane(for: .foregroundGeneration), .gpu)
        XCTAssertEqual(gate.lane(for: .mediaDiffusion), .gpu)
        XCTAssertEqual(gate.lane(for: .toolRoute), .cpuTernary)
        XCTAssertEqual(gate.lane(for: .classify), .cpuTernary)
        XCTAssertEqual(gate.lane(for: .memoryRetrieval), .cpuTernary)
        XCTAssertEqual(gate.lane(for: .parkedSubagent), .cpuTernary)
    }

    // MARK: - §5.3 media/vision never routes to the CPU lane (verified via the policy)

    func testMediaDiffusionKeepsMediaOffTheCPULane() {
        let routing = DefaultLaneRouting()
        XCTAssertEqual(routing.lane(for: .mediaDiffusion), .gpu)
        // And under the gate ON, media is still GPU.
        let gate = GatedLaneRouting(fullPotentialEnabled: true, cpuLaneEnabled: true)
        XCTAssertEqual(gate.lane(for: .mediaDiffusion), .gpu)
    }
}
