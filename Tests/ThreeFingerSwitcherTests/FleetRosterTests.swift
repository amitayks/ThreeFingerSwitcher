import XCTest
@testable import ThreeFingerSwitcherCore

/// Fleet enums, the extended `ModelDescriptor`, the `ModelRegistry` protocol, `FleetRoster`, and the
/// `StubModelRegistry` (tasks 1.1, 1.2, 2.1, 2.2, 2.3). Pure Core — no weights, no network.
final class FleetRosterTests: XCTestCase {

    // MARK: - 1.1 Enums (exhaustive cases)

    func testModelRoleCases() {
        XCTAssertEqual(Set(ModelRole.allCases),
                       [.chat, .ternaryChat, .image, .video, .cloudEscalation])
    }

    func testModelProviderCases() {
        XCTAssertEqual(Set(ModelProvider.allCases), [.onDevice, .cloud])
    }

    // MARK: - 1.2 Extended descriptor defaults

    /// A bare construction (pre-fleet shape) defaults to the single-GPU-chat fleet shape, and the new
    /// fields read back. `residencyBytes` derives from `sizeBytes` when unset (additive D1).
    func testDescriptorDefaultsMatchFleetOfOne() {
        let d = ModelDescriptor(
            id: "chat", displayName: "Chat",
            sizeBytes: 17 * 1024 * 1024 * 1024,
            integritySHA: "x",
            downloadURL: URL(string: "https://example.com")!,
            capabilities: [.text, .vision],
            quantization: .qat4bit)
        XCTAssertEqual(d.role, .chat)
        XCTAssertEqual(d.lane, .gpu)
        XCTAssertEqual(d.provider, .onDevice)
        XCTAssertEqual(d.maxContextTokens, 131_072)
        // Derived from sizeBytes when the caller passes no explicit residencyBytes.
        XCTAssertEqual(d.residencyBytes, UInt64(17 * 1024 * 1024 * 1024))
    }

    func testDescriptorExplicitFleetFields() {
        let cloud = ModelDescriptor(
            id: "glm", displayName: "GLM-5.2",
            sizeBytes: 0, integritySHA: "cloud",
            downloadURL: URL(string: "https://open.bigmodel.cn")!,
            capabilities: [.text, .vision], quantization: .bf16,
            maxContextTokens: 1_000_000,
            role: .cloudEscalation, lane: nil, provider: .cloud, residencyBytes: 0)
        XCTAssertEqual(cloud.role, .cloudEscalation)
        XCTAssertNil(cloud.lane)
        XCTAssertEqual(cloud.provider, .cloud)
        XCTAssertEqual(cloud.residencyBytes, 0)
    }

    // MARK: - 2.2 FleetRoster

    func testStandardRosterDescriptorsIncludeBothCloudMembers() {
        let ids = FleetRoster.standard.descriptors().map(\.id)
        XCTAssertTrue(ids.contains("gemma-4-31b"))      // chat
        XCTAssertTrue(ids.contains("ternary-cpu-chat"))  // ternary
        XCTAssertTrue(ids.contains("image-q4"))
        XCTAssertTrue(ids.contains("image-fp16"))
        XCTAssertTrue(ids.contains("video-ltxv"))
        XCTAssertTrue(ids.contains("claude-cloud"))
        XCTAssertTrue(ids.contains("glm-5.2-cloud"))
    }

    func testGLM52FactsInNameAndCapabilities() {
        let glm = FleetRoster.standard.descriptor(id: "glm-5.2-cloud")
        XCTAssertNotNil(glm)
        XCTAssertTrue(glm!.displayName.contains("753B"))
        XCTAssertTrue(glm!.displayName.contains("MIT"))
        XCTAssertEqual(glm!.maxContextTokens, 1_000_000)
        XCTAssertEqual(glm!.provider, .cloud)
        XCTAssertEqual(glm!.role, .cloudEscalation)
        XCTAssertEqual(glm!.residencyBytes, 0)
    }

    /// `resident()` never includes any cloud member even after ensureResident on it (cloud is a no-op).
    func testResidentExcludesEveryCloudMember() async throws {
        let roster = FleetRoster.standard
        try await roster.ensureResident("claude-cloud")
        try await roster.ensureResident("glm-5.2-cloud")
        let residentProviders = roster.resident().map(\.provider)
        XCTAssertFalse(residentProviders.contains(.cloud))
        XCTAssertTrue(roster.resident().isEmpty, "cloud admissions never make anything resident")
    }

    func testCapabilitySelectionFindsChatModel() throws {
        let chat = try FleetRoster.standard.selectModel(requiring: [.text])
        XCTAssertEqual(chat.role, .chat)
        XCTAssertEqual(chat.id, "gemma-4-31b")
    }

    // MARK: - 2.3 StubModelRegistry

    func testFleetOfOneConforms() async throws {
        let reg: ModelRegistry = StubModelRegistry.fleetOfOne()
        XCTAssertEqual(reg.descriptors().count, 1)
        try await reg.ensureResident("gemma-4-31b")
        XCTAssertEqual(reg.resident().map(\.id), ["gemma-4-31b"])
    }

    func testScriptedMultiMemberRosterQueryable() {
        let stub = StubModelRegistry(members: [
            descriptor(id: "a", role: .chat, lane: .gpu, bytes: 1),
            descriptor(id: "b", role: .ternaryChat, lane: .cpuTernary, bytes: 1)
        ])
        XCTAssertEqual(Set(stub.descriptors().map(\.id)), ["a", "b"])
        XCTAssertEqual(stub.descriptor(id: "b")?.role, .ternaryChat)
    }

    // MARK: - Helper

    private func descriptor(id: String, role: ModelRole, lane: ComputeLane?, bytes: UInt64,
                            provider: ModelProvider = .onDevice) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id, sizeBytes: Int64(bytes), integritySHA: "x",
                        downloadURL: URL(string: "https://example.com/\(id)")!,
                        capabilities: [.text], quantization: .qat4bit,
                        role: role, lane: lane, provider: provider, residencyBytes: bytes)
    }
}
