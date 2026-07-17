import Foundation

/// The standard fleet roster (design D2) — the §C1 `ModelRegistry` conformer that lists the V2.5 fleet:
///  - **chat** — Gemma on the GPU lane (the default, today's single model).
///  - **ternary** — the small CPU-lane model (`.cpuTernary`, ~0.5 GB resident), co-resides with chat.
///  - **image (Q4)** — a 4-bit generative-image backend (~7 GB), CO-RESIDES with chat + ternary + KV.
///  - **image (FP16)** — the full-precision image variant (~24 GB resident), EVICTS chat.
///  - **video** — a generative-video backend, EVICTS chat (the companion goes quiet while it paints).
///  - **Claude** + **GLM-5.2** — the two CLOUD members (`provider: .cloud`, `role: .cloudEscalation`,
///    `residencyBytes: 0`): visible/selectable in `descriptors()` for the Hub roster + escalation
///    routing, but NEVER in `resident()` and never loaded. GLM-5.2 (753B MoE / 1M ctx / MIT) does not fit
///    48 GB — local residency is not an option.
///
/// `descriptors()` returns ALL members (cloud included). `resident()` returns only the on-device members
/// currently loaded (cloud is never resident). `ensureResident` runs the `ResidencyPlanner` and records
/// the resident bookkeeping IN MEMORY — it does NOT touch real weights; the live load is `ModelManager`'s
/// job (D4). So FleetRoster is the `swift test`-verified roster + planning view, and ModelManager is the
/// live one. A fleet-of-one is `FleetRoster(members: [chat])` — trivially today's behavior.
///
/// MLX-free Core. Only the user's stable-signed build proves the REAL residency/eviction with real
/// weights (does Video actually evict chat + reload? does Q4 image truly co-reside under 48 GB?).
public final class FleetRoster: ModelRegistry, @unchecked Sendable {

    private let members: [ModelDescriptor]
    private let planner: ResidencyPlanner
    /// The unified-memory budget the planner spends against (the 48 GB target by default).
    private let budgetBytes: UInt64
    /// Injected live free-memory probe (mirrors `LaneResidencyBudget`); pure value in tests.
    private let freeBytesProbe: @Sendable () -> UInt64

    /// Resident bookkeeping (ids loaded). Mutated by `ensureResident` — in-memory only, NO real weights.
    private let lock = NSLock()
    private var residentIDs: [String] = []

    public init(members: [ModelDescriptor],
                planner: ResidencyPlanner = ResidencyPlanner(),
                budgetBytes: UInt64 = FleetRoster.unifiedBudget48GB,
                freeBytesProbe: @escaping @Sendable () -> UInt64 = { FleetRoster.unifiedBudget48GB }) {
        self.members = members
        self.planner = planner
        self.budgetBytes = budgetBytes
        self.freeBytesProbe = freeBytesProbe
    }

    /// The 48 GB unified-memory budget on the M5 Pro target (the hard, shared budget this slice encodes).
    public static let unifiedBudget48GB: UInt64 = 48 * 1024 * 1024 * 1024

    // MARK: - ModelRegistry

    public func descriptors() -> [ModelDescriptor] { members }

    public func resident() -> [ModelDescriptor] {
        lock.lock(); defer { lock.unlock() }
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        // Cloud members can never be resident, even if an id slipped in — filter defensively.
        return residentIDs.compactMap { byID[$0] }.filter { $0.provider == .onDevice }
    }

    public func ensureResident(_ id: String) async throws {
        guard let target = members.first(where: { $0.id == id }) else {
            throw RuntimeError.modelMissing
        }
        // Cloud target → residency no-op (it routes to escalation; this view never loads it).
        if target.provider == .cloud { return }

        let plan = planner.plan(target: id,
                                descriptors: members,
                                budgetBytes: budgetBytes,
                                freeBytes: freeBytesProbe(),
                                currentlyResident: snapshotResident())
        if plan.infeasible {
            throw FleetError.cannotAdmit(modelName: target.displayName,
                                         evictedDetails: plan.evict.isEmpty ? nil
                                            : "Tried to evict: \(plan.evict.joined(separator: ", "))")
        }
        // Apply the plan to the in-memory bookkeeping (NO real weights here).
        lock.lock()
        residentIDs.removeAll { plan.evict.contains($0) }
        for admitted in plan.admit where !residentIDs.contains(admitted) {
            residentIDs.append(admitted)
        }
        lock.unlock()
    }

    private func snapshotResident() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return residentIDs
    }

    // MARK: - Selection helpers (parity with the value catalog)

    /// Look up a member by id.
    public func descriptor(id: String) -> ModelDescriptor? {
        members.first { $0.id == id }
    }

    /// Capability-based selection over the ON-DEVICE members (cloud members are escalation targets, never
    /// capability-selected here): the first member satisfying ALL required capabilities, or a clear
    /// failure. Preserves the value catalog's behavior so the executor's `runtime(requiring:)` still
    /// finds the chat model.
    public func selectModel(requiring required: Set<Modality>) throws -> ModelDescriptor {
        let candidates = members.filter { $0.provider == .onDevice && required.isSubset(of: $0.capabilities) }
        guard let first = candidates.first else {
            let names = required.map(\.rawValue).sorted().joined(separator: ", ")
            throw RuntimeError.unavailable(reason: "No registered model satisfies required capabilities: [\(names)]")
        }
        return first
    }

    // MARK: - The standard fleet

    /// The built-in V2.5 fleet. Chat + ternary + Q4 image co-reside under 48 GB; FP16 image + video evict
    /// chat; Claude + GLM-5.2 are cloud-only. Resident-byte numbers are honest approximations of the real
    /// footprints (the user's stable-signed build verifies the live bytes).
    public static let standard = FleetRoster(members: [
        // chat — GPU lane, ~17 GB resident (today's default model).
        ModelDescriptor(
            id: "gemma-4-31b",
            displayName: "Gemma 4 31B (chat, text + vision, 4-bit)",
            sizeBytes: 17 * 1024 * 1024 * 1024,
            integritySHA: "hub-verified",
            downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-31b-it-4bit")!,
            capabilities: [.text, .vision],
            quantization: .qat4bit,
            maxContextTokens: 131_072,
            role: .chat,
            lane: .gpu,
            provider: .onDevice,
            residencyBytes: 17 * 1024 * 1024 * 1024
        ),
        // ternary — CPU lane, ~0.5 GB resident, co-resides (bandwidth-frugal; ~32× smaller weights).
        ModelDescriptor(
            id: "ternary-cpu-chat",
            displayName: "Ternary CPU model (routing / classify, ~0.5 GB)",
            sizeBytes: 512 * 1024 * 1024,
            integritySHA: "hub-verified",
            downloadURL: URL(string: "https://huggingface.co/mlx-community/ternary-cpu-chat")!,
            capabilities: [.text],
            quantization: .int8,
            maxContextTokens: 8_192,
            role: .ternaryChat,
            lane: .cpuTernary,
            provider: .onDevice,
            residencyBytes: 512 * 1024 * 1024
        ),
        // image (Q4) — GPU lane, ~7 GB resident, CO-RESIDES with chat + ternary + KV under 48 GB.
        ModelDescriptor(
            id: "image-q4",
            displayName: "FLUX.2 Klein 4B (4-bit, ~7 GB) — co-resides with chat",
            sizeBytes: 7 * 1024 * 1024 * 1024,
            integritySHA: "hub-verified",
            downloadURL: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B")!,
            capabilities: [.text, .vision],
            quantization: .qat4bit,
            maxContextTokens: 8_192,
            role: .image,
            lane: .gpu,
            provider: .onDevice,
            residencyBytes: 7 * 1024 * 1024 * 1024
        ),
        // image (FP16) — GPU lane, ~24 GB resident, EVICTS chat (above the FP16 threshold).
        ModelDescriptor(
            id: "image-fp16",
            displayName: "FLUX.2 Klein 4B (bf16, ~24 GB) — pauses chat while it paints",
            sizeBytes: 24 * 1024 * 1024 * 1024,
            integritySHA: "hub-verified",
            downloadURL: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B")!,
            capabilities: [.text, .vision],
            quantization: .fp16,
            maxContextTokens: 8_192,
            role: .image,
            lane: .gpu,
            provider: .onDevice,
            residencyBytes: 24 * 1024 * 1024 * 1024
        ),
        // video — GPU lane, ~24 GB resident, EVICTS chat (always evicts regardless of size).
        ModelDescriptor(
            id: "video-ltxv",
            displayName: "Video model (LTXV) — pauses chat while it animates",
            sizeBytes: 24 * 1024 * 1024 * 1024,
            integritySHA: "hub-verified",
            downloadURL: URL(string: "https://huggingface.co/mlx-community/video-ltxv")!,
            capabilities: [.text, .vision],
            quantization: .fp16,
            maxContextTokens: 8_192,
            role: .video,
            lane: .gpu,
            provider: .onDevice,
            residencyBytes: 24 * 1024 * 1024 * 1024
        ),
        // Claude — CLOUD escalation member, never resident (residencyBytes 0, lane nil).
        ModelDescriptor(
            id: "claude-cloud",
            displayName: "Claude (cloud) — escalation, not resident locally",
            sizeBytes: 0,
            integritySHA: "cloud",
            downloadURL: URL(string: "https://api.anthropic.com")!,
            capabilities: [.text, .vision],
            quantization: .bf16,
            maxContextTokens: 200_000,
            role: .cloudEscalation,
            lane: nil,
            provider: .cloud,
            residencyBytes: 0
        ),
        // GLM-5.2 — CLOUD escalation member (753B MoE / 1M ctx / MIT). Does NOT fit 48 GB — cloud only.
        ModelDescriptor(
            id: "glm-5.2-cloud",
            displayName: "GLM-5.2 (cloud) — 753B MoE, 1M context, MIT (escalation only)",
            sizeBytes: 0,
            integritySHA: "cloud",
            downloadURL: URL(string: "https://open.bigmodel.cn")!,
            capabilities: [.text, .vision],
            quantization: .bf16,
            maxContextTokens: 1_000_000,
            role: .cloudEscalation,
            lane: nil,
            provider: .cloud,
            residencyBytes: 0
        )
    ])
}

/// A test-only roster (design D2, task 2.3) that scripts an ARBITRARY set of members — including the
/// degenerate fleet-of-one (just the chat descriptor → today's behavior). A thin wrapper over
/// `FleetRoster` so the conformance + planning are exercised identically to production.
public final class StubModelRegistry: ModelRegistry, @unchecked Sendable {
    private let roster: FleetRoster

    public init(members: [ModelDescriptor],
                planner: ResidencyPlanner = ResidencyPlanner(),
                budgetBytes: UInt64 = FleetRoster.unifiedBudget48GB,
                freeBytesProbe: @escaping @Sendable () -> UInt64 = { FleetRoster.unifiedBudget48GB }) {
        self.roster = FleetRoster(members: members, planner: planner,
                                  budgetBytes: budgetBytes, freeBytesProbe: freeBytesProbe)
    }

    /// A fleet-of-one: a single chat descriptor (today's single-model shape, with fleet defaults).
    public static func fleetOfOne(id: String = "gemma-4-31b") -> StubModelRegistry {
        StubModelRegistry(members: [
            ModelDescriptor(
                id: id,
                displayName: "Gemma 4 (chat)",
                sizeBytes: 17 * 1024 * 1024 * 1024,
                integritySHA: "hub-verified",
                downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-31b-it-4bit")!,
                capabilities: [.text, .vision],
                quantization: .qat4bit,
                role: .chat,
                lane: .gpu,
                provider: .onDevice,
                residencyBytes: 17 * 1024 * 1024 * 1024)
        ])
    }

    public func descriptors() -> [ModelDescriptor] { roster.descriptors() }
    public func resident() -> [ModelDescriptor] { roster.resident() }
    public func ensureResident(_ id: String) async throws { try await roster.ensureResident(id) }
    public func descriptor(id: String) -> ModelDescriptor? { roster.descriptor(id: id) }
    public func selectModel(requiring required: Set<Modality>) throws -> ModelDescriptor {
        try roster.selectModel(requiring: required)
    }
}
