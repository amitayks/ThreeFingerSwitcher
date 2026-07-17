import XCTest
@testable import ThreeFingerSwitcherCore

/// `ModelManager` consuming the fleet registry + planner around the EXISTING provisioner/runtimeFactory
/// (tasks 5.1–5.3, 6.2). Dev-stub path — no real weights. `StubLLMRuntime`-backed.
@MainActor
final class ModelManagerFleetTests: XCTestCase {

    private let GB: UInt64 = 1024 * 1024 * 1024

    // A downloader that's never used on the fleet path (loadDescriptor uses the runtimeFactory).
    private struct UnusedDownloader: ModelDownloading {
        func download(_ d: ModelDescriptor, to: URL, progress: @Sendable (Double) -> Void) async throws -> Data {
            Data()
        }
    }

    /// Records every descriptor id the runtimeFactory builds, so a test can assert load order.
    private final class LoadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var loaded: [String] = []
        func record(_ id: String) { lock.lock(); loaded.append(id); lock.unlock() }
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return loaded }
    }

    private func descriptor(_ id: String, role: ModelRole, lane: ComputeLane?, gb: UInt64,
                            provider: ModelProvider = .onDevice) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id, sizeBytes: Int64(gb * GB), integritySHA: "x",
                        downloadURL: URL(string: "https://example.com/\(id)")!,
                        capabilities: [.text], quantization: .qat4bit,
                        role: role, lane: lane, provider: provider, residencyBytes: gb * GB)
    }

    private func chat() -> ModelDescriptor { descriptor("chat", role: .chat, lane: .gpu, gb: 17) }
    private func ternary() -> ModelDescriptor { descriptor("ternary", role: .ternaryChat, lane: .cpuTernary, gb: 1) }
    private func video() -> ModelDescriptor { descriptor("video", role: .video, lane: .gpu, gb: 24) }
    private func cloud() -> ModelDescriptor { descriptor("cloud", role: .cloudEscalation, lane: nil, gb: 0, provider: .cloud) }

    private func manager(members: [ModelDescriptor],
                         recorder: LoadRecorder,
                         cloudGate: FleetCloudGate = FleetCloudGate(),
                         freeBytes: @escaping @Sendable () -> UInt64 = { 48 * 1024 * 1024 * 1024 }) -> ModelManager {
        let fleet = FleetRoster(members: members, freeBytesProbe: freeBytes)
        let m = ModelManager(
            downloader: UnusedDownloader(),
            optedIn: true,
            fleet: fleet,
            fleetFreeBytes: freeBytes,
            cloudGate: cloudGate,
            runtimeFactory: { d in
                recorder.record(d.id)
                return StubLLMRuntime(capabilities: d.capabilities)
            })
        return m
    }

    // MARK: - 5.1 evict-then-load

    func testEnsureResidentEvictsThenLoadsTarget() async throws {
        let rec = LoadRecorder()
        let m = manager(members: [chat(), ternary(), video()], recorder: rec)

        // Load chat resident first.
        try await m.ensureResident("chat")
        XCTAssertEqual(rec.ids, ["chat"])
        XCTAssertTrue(m.isResident)

        // Admitting video must evict chat (the resident runtime) then load video.
        try await m.ensureResident("video")
        XCTAssertEqual(rec.ids, ["chat", "video"], "video loaded after chat was evicted")
        // The fleet's resident view no longer lists chat.
        XCTAssertFalse(m.fleetResident().map(\.id).contains("chat"))
        XCTAssertTrue(m.fleetResident().map(\.id).contains("video"))
    }

    /// A cannotAdmit plan throws FleetError.cannotAdmit and leaves state .failed, never a false .loaded.
    func testCannotAdmitThrowsAndFails() async throws {
        let rec = LoadRecorder()
        let huge = descriptor("huge", role: .video, lane: .gpu, gb: 60)
        let m = manager(members: [chat(), ternary(), huge], recorder: rec)
        try await m.ensureResident("chat")

        do {
            try await m.ensureResident("huge")
            XCTFail("expected cannotAdmit")
        } catch let error as FleetError {
            guard case .cannotAdmit = error else { return XCTFail("wrong case: \(error)") }
        }
        if case .failed = m.state {} else { XCTFail("state must be .failed, not a false .loaded") }
    }

    // MARK: - 5.2 fleet-of-one

    func testFleetOfOneLoadsLikeSingleModel() async throws {
        let rec = LoadRecorder()
        let m = manager(members: [chat()], recorder: rec)
        try await m.ensureResident("chat")
        XCTAssertEqual(rec.ids, ["chat"], "no eviction, a single lazy load")
        XCTAssertTrue(m.isResident)
        if case .loaded = m.state {} else { XCTFail("fleet-of-one settles .loaded") }
        // A second ensureResident of the same model is a warm hit (no re-load).
        try await m.ensureResident("chat")
        XCTAssertEqual(rec.ids, ["chat"], "warm hit re-loads nothing")
    }

    // MARK: - 5.3 cloud no-op

    func testCloudEnsureResidentIsResidencyNoOp() async throws {
        let rec = LoadRecorder()
        // Cloud enabled so select() routes (no throw); residency must still be untouched.
        let gate = FleetCloudGate(isEnabled: { true })
        let m = manager(members: [chat(), cloud()], recorder: rec, cloudGate: gate)
        try await m.ensureResident("chat")
        let before = m.fleetResident().map(\.id)

        try await m.ensureResident("cloud")
        XCTAssertEqual(rec.ids, ["chat"], "cloud never loads weights")
        XCTAssertEqual(m.fleetResident().map(\.id), before, "resident() unchanged by a cloud admission")
    }

    // MARK: - 6.2 cloud gating

    func testCloudDisabledThrowsCloudDisabled() async throws {
        let rec = LoadRecorder()
        let gate = FleetCloudGate(isEnabled: { false }) // cloud OFF
        let m = manager(members: [chat(), cloud()], recorder: rec, cloudGate: gate)
        do {
            try await m.ensureResident("cloud")
            XCTFail("expected cloudDisabled")
        } catch let error as FleetError {
            guard case .cloudDisabled = error else { return XCTFail("wrong case: \(error)") }
        }
        XCTAssertTrue(rec.ids.isEmpty, "nothing loaded for a gated-off cloud member")
    }

    func testCloudEnabledRoutesToHandoffSpy() async throws {
        final class EscalationSpy: FleetCloudEscalating, @unchecked Sendable {
            let lock = NSLock(); private(set) var routed: [String] = []
            func escalate(to descriptor: ModelDescriptor) async throws {
                lock.lock(); routed.append(descriptor.id); lock.unlock()
            }
            var ids: [String] { lock.lock(); defer { lock.unlock() }; return routed }
        }
        let spy = EscalationSpy()
        let gate = FleetCloudGate(isEnabled: { true }, escalator: spy)
        let rec = LoadRecorder()
        let m = manager(members: [chat(), cloud()], recorder: rec, cloudGate: gate)
        try await m.ensureResident("cloud")
        XCTAssertEqual(spy.ids, ["cloud"], "an enabled cloud selection routes to the escalation seam")
        XCTAssertTrue(rec.ids.isEmpty, "still loads no weights")
    }

    // MARK: - 6.2 selectableDescriptors gating

    func testSelectableDescriptorsHidesCloudWhenOff() {
        let descs = [chat(), cloud()]
        let off = FleetCloudGate(isEnabled: { false })
        XCTAssertEqual(off.selectableDescriptors(from: descs).map(\.id), ["chat"])
        let on = FleetCloudGate(isEnabled: { true })
        XCTAssertEqual(Set(on.selectableDescriptors(from: descs).map(\.id)), ["chat", "cloud"])
    }
}
