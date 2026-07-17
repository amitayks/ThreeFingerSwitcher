import XCTest
@testable import ThreeFingerSwitcherCore

/// The pure residency / eviction MATH (tasks 3.1–3.4, design D3). No Metal, fixed injected free-memory.
final class ResidencyPlannerTests: XCTestCase {

    private let GB: UInt64 = 1024 * 1024 * 1024

    private func descriptor(_ id: String, role: ModelRole, lane: ComputeLane?, gb: UInt64,
                            provider: ModelProvider = .onDevice) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id, sizeBytes: Int64(gb * GB), integritySHA: "x",
                        downloadURL: URL(string: "https://example.com/\(id)")!,
                        capabilities: [.text], quantization: .qat4bit,
                        role: role, lane: lane, provider: provider, residencyBytes: gb * GB)
    }

    /// The standard fleet shapes used across cases.
    private var fleet: [ModelDescriptor] {
        [
            descriptor("chat", role: .chat, lane: .gpu, gb: 17),
            descriptor("ternary", role: .ternaryChat, lane: .cpuTernary, gb: 1),
            descriptor("imageQ4", role: .image, lane: .gpu, gb: 7),
            descriptor("imageFP16", role: .image, lane: .gpu, gb: 24),
            descriptor("video", role: .video, lane: .gpu, gb: 24),
            descriptor("cloud", role: .cloudEscalation, lane: nil, gb: 0, provider: .cloud)
        ]
    }

    private let budget: UInt64 = 48 * 1024 * 1024 * 1024

    // MARK: - 3.2 Co-residency

    /// Q4 image co-resides with chat + ternary + KV under 48 GB (no eviction).
    func testQ4ImageCoResidesWithChatTernaryKV() {
        let planner = ResidencyPlanner(kvReserveBytes: 4 * GB, fp16ImageThresholdBytes: 16 * GB)
        let plan = planner.plan(target: "imageQ4", descriptors: fleet,
                                budgetBytes: budget, freeBytes: budget,
                                currentlyResident: ["chat", "ternary"])
        XCTAssertEqual(plan.admit, ["imageQ4"])
        XCTAssertTrue(plan.evict.isEmpty, "Q4 image must co-reside, not evict")
        XCTAssertFalse(plan.infeasible)
        XCTAssertEqual(Set(plan.coResident), ["chat", "ternary", "imageQ4"])
        // 17 + 1 + 7 + 4(KV) = 29 GB ≤ 48 GB.
    }

    // MARK: - 3.3 Eviction trigger

    func testVideoEvictsChatTernarySurvives() {
        let planner = ResidencyPlanner(kvReserveBytes: 4 * GB)
        let plan = planner.plan(target: "video", descriptors: fleet,
                                budgetBytes: budget, freeBytes: budget,
                                currentlyResident: ["chat", "ternary"])
        XCTAssertEqual(plan.admit, ["video"])
        XCTAssertTrue(plan.evict.contains("chat"), "video must evict the GPU-lane chat")
        XCTAssertFalse(plan.evict.contains("ternary"), "the CPU-lane ternary survives a GPU gen")
        XCTAssertTrue(plan.coResident.contains("ternary"))
        XCTAssertTrue(plan.coResident.contains("video"))
        XCTAssertFalse(plan.coResident.contains("chat"))
        XCTAssertFalse(plan.infeasible)
        // 17(chat) + 1 + 24(video) + 4 = 46 ≤ 48, but the planner still evicts chat because chat + video
        // + KV (17 + 24 + 4 = 45) already needs chat gone for headroom past KV... assert the documented
        // behavior: chat is evicted so the heavy gen owns the GPU budget.
    }

    func testFP16ImageEvictsChat() {
        let planner = ResidencyPlanner(kvReserveBytes: 4 * GB)
        let plan = planner.plan(target: "imageFP16", descriptors: fleet,
                                budgetBytes: budget, freeBytes: budget,
                                currentlyResident: ["chat", "ternary"])
        XCTAssertEqual(plan.admit, ["imageFP16"])
        XCTAssertTrue(plan.evict.contains("chat"))
        XCTAssertFalse(plan.evict.contains("ternary"))
        XCTAssertFalse(plan.infeasible)
    }

    // MARK: - 3.4 Cloud + infeasible

    func testCloudTargetEmptyPlan() {
        let planner = ResidencyPlanner()
        let plan = planner.plan(target: "cloud", descriptors: fleet,
                                budgetBytes: budget, freeBytes: budget,
                                currentlyResident: ["chat", "ternary"])
        XCTAssertTrue(plan.admit.isEmpty)
        XCTAssertTrue(plan.evict.isEmpty)
        XCTAssertFalse(plan.infeasible)
        XCTAssertEqual(Set(plan.coResident), ["chat", "ternary"])
    }

    /// A target larger than the whole budget cannot fit even after evicting everything → infeasible.
    func testOverBudgetReportsInfeasible() {
        let huge = descriptor("huge", role: .video, lane: .gpu, gb: 60) // > 48 GB on its own
        let planner = ResidencyPlanner(kvReserveBytes: 4 * GB)
        let plan = planner.plan(target: "huge",
                                descriptors: fleet + [huge],
                                budgetBytes: budget, freeBytes: budget,
                                currentlyResident: ["chat", "ternary"])
        XCTAssertTrue(plan.infeasible)
        XCTAssertTrue(plan.admit.isEmpty, "an infeasible target is never admitted")
    }

    /// Already-resident target → warm, nothing to do.
    func testAlreadyResidentWarm() {
        let planner = ResidencyPlanner()
        let plan = planner.plan(target: "chat", descriptors: fleet,
                                budgetBytes: budget, freeBytes: budget,
                                currentlyResident: ["chat"])
        XCTAssertTrue(plan.admit.isEmpty)
        XCTAssertTrue(plan.evict.isEmpty)
    }

    // MARK: - 7.2 admissionEvictsChat (plan → warning)

    func testAdmissionEvictsChatMapping() {
        let planner = ResidencyPlanner(kvReserveBytes: 4 * GB)
        XCTAssertTrue(planner.admissionEvictsChat(targetID: "video", descriptors: fleet,
                                                  budgetBytes: budget, freeBytes: budget,
                                                  currentlyResident: ["chat", "ternary"]))
        XCTAssertTrue(planner.admissionEvictsChat(targetID: "imageFP16", descriptors: fleet,
                                                  budgetBytes: budget, freeBytes: budget,
                                                  currentlyResident: ["chat", "ternary"]))
        XCTAssertFalse(planner.admissionEvictsChat(targetID: "imageQ4", descriptors: fleet,
                                                   budgetBytes: budget, freeBytes: budget,
                                                   currentlyResident: ["chat", "ternary"]),
                       "Q4 image co-resides → no evict-chat warning")
    }
}
