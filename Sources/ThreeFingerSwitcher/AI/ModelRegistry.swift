import Foundation

// MARK: - Fleet enums (addendum §C1 — OWNED by `ai-model-fleet`)

/// The KIND of model a descriptor names — the fleet's coarse classification (addendum §C1). It drives
/// the residency/eviction math (a `.video` / large `.image` gen evicts the GPU-lane `.chat` model; the
/// `.ternaryChat` model co-resides on the CPU lane) and the Hub roster's role badge.
///
/// `.cloudEscalation` members (Claude, GLM-5.2) are NEVER resident locally — they ride the existing
/// Claude-handoff escalation paths and are off until `fleetCloudEscalationEnabled`.
public enum ModelRole: String, Codable, Sendable, CaseIterable {
    case chat              // Gemma on the GPU lane
    case ternaryChat       // the small CPU-lane model
    case image             // generative image backend
    case video             // generative video backend
    case cloudEscalation   // Claude, GLM-5.2 — NOT resident locally
}

/// Where a model physically runs (addendum §C1). `.onDevice` models occupy unified-memory budget and are
/// subject to the residency planner; `.cloud` members never occupy bytes and are never resident.
public enum ModelProvider: String, Codable, Sendable, CaseIterable {
    case onDevice
    case cloud
}

// MARK: - Model descriptor

/// A description of one known model: enough to download it, verify it, and route commands to it by
/// capability. The registry keeps model/runtime version churn off the feature code (design D1, the
/// "registry drives upgrades" scenario): a newer entry becomes selectable via configuration, not a
/// code change in the band/executor/tasks.
///
/// The fleet fields (`role`/`lane`/`provider`/`residencyBytes`) are ADDITIVE (design D1): every existing
/// construction site keeps compiling because the new parameters default to the single-GPU-chat shape
/// (`role: .chat`, `lane: .gpu`, `provider: .onDevice`, `residencyBytes` derived from `sizeBytes`). A
/// fleet-of-one is exactly today's descriptor with those defaults.
///
/// §C1 note: §C1 sketches the descriptor as `Codable` with `capabilities: Set<String>`. We honor its
/// FIELD SHAPE verbatim but keep the LIVE type — `Equatable, Sendable, Identifiable` (NOT `Codable`) and
/// `capabilities: Set<Modality>` (the live capability set, image/video tags mapped onto `Modality`). The
/// persisted artifact is the selected model *id* (`ModelSelector`), never the descriptor, so no `Codable`
/// is needed and the existing persistence is untouched.
public struct ModelDescriptor: Equatable, Sendable, Identifiable {
    /// Stable identifier (also the on-disk folder name).
    public var id: String
    /// Human-facing name for Settings.
    public var displayName: String
    /// Approximate on-disk weight size, in bytes (for the download prompt / progress).
    public var sizeBytes: Int64
    /// Expected SHA-256 (hex) of the downloaded weights; verified before first load.
    public var integritySHA: String
    /// Where the weights are fetched from (only after opt-in).
    public var downloadURL: URL
    /// What this model can serve. A vision command requires `.vision`; `.audio` is reserved; the media
    /// roles carry `.image`/`.video` tags (mapped onto `Modality` — §C1's image/video string-tags).
    public var capabilities: Set<Modality>
    /// Quantization scheme of the published weights (informational + selection tie-breaks later).
    public var quantization: Quantization
    /// The model's architectural maximum context length, in tokens. DECLARED ONCE by
    /// `ai-batched-runtime-and-context` (design D5) and CARRIED here unchanged — this slice does NOT
    /// re-declare it (SLICE NOTE). It is the CLAMP CEILING for the user-adjustable `agentContextTokens`;
    /// media/cloud members simply carry a value they never consult. §C1 sketches it `Int?`; the live
    /// type is the already-shipped non-optional `Int`.
    public var maxContextTokens: Int
    /// The fleet ROLE (addendum §C1). Defaults `.chat` so a bare descriptor is today's single chat model.
    public var role: ModelRole
    /// The physical compute lane (addendum §A1, consumed verbatim from `ai-compute-tiers` — NOT redefined
    /// here). `nil` for cloud members (they run in a datacenter, not on a local lane).
    public var lane: ComputeLane?
    /// On-device vs cloud (addendum §C1). Defaults `.onDevice`.
    public var provider: ModelProvider
    /// The model's RESIDENT (in-memory) footprint in bytes — the number the `ResidencyPlanner` budgets
    /// against the 48 GB unified-memory budget (DISTINCT from `sizeBytes`, the on-disk download size).
    /// 0 for cloud members (never resident). Defaults to `sizeBytes` (a reasonable on-device resident
    /// approximation) when the caller does not pass an explicit value.
    public var residencyBytes: UInt64

    public enum Quantization: String, Codable, Sendable {
        case qat4bit   // QAT 4-bit (the shipped default for Apple Silicon)
        case int8
        case bf16
        case fp16      // full-precision image weights (the FP16 image variant that evicts chat)
    }

    /// Sentinel passed to the init's `residencyBytes` parameter to mean "derive from `sizeBytes`". A
    /// real model's resident footprint is never `.max`, so this is an unambiguous unset marker that keeps
    /// the parameter additive without forcing every existing call site to compute a byte count.
    public static let deriveResidencyBytes: UInt64 = .max

    public init(id: String,
                displayName: String,
                sizeBytes: Int64,
                integritySHA: String,
                downloadURL: URL,
                capabilities: Set<Modality>,
                quantization: Quantization,
                maxContextTokens: Int = 131_072,
                role: ModelRole = .chat,
                lane: ComputeLane? = .gpu,
                provider: ModelProvider = .onDevice,
                residencyBytes: UInt64 = ModelDescriptor.deriveResidencyBytes) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.integritySHA = integritySHA
        self.downloadURL = downloadURL
        self.capabilities = capabilities
        self.quantization = quantization
        self.maxContextTokens = maxContextTokens
        self.role = role
        self.lane = lane
        self.provider = provider
        // Derive the resident footprint from the on-disk size when the caller leaves it unset — keeps
        // every pre-fleet construction site (which passes no `residencyBytes`) compiling AND honest:
        // a chat model's resident weights ≈ its 4-bit on-disk size. Cloud members pass an explicit 0.
        if residencyBytes == ModelDescriptor.deriveResidencyBytes {
            self.residencyBytes = UInt64(max(0, sizeBytes))
        } else {
            self.residencyBytes = residencyBytes
        }
    }
}

/// The set of known Gemma 4 models and capability-based selection over them.
///
/// v1 ships:
/// - **31B** (dense, text+vision) — the default, best quality the target hardware allows (design D1).
/// - **26B-A4B** (MoE, text+vision) — the documented faster alternative; switching the default is a
///   one-line change here (`defaultModelID`) because feature code only sees `LLMRuntime`.
/// - **12B** (text+vision+**audio**) — reserved so a future audio command routes to it via the seam
///   (design: audio is out of v1 scope but selectable later without feature changes).
///
/// NAMING (this slice): the §C1 fleet protocol is named `ModelRegistry` (it conforms `FleetRoster`).
/// This pre-existing value catalog therefore renames to `ModelCatalog` — same shape, same `.standard`,
/// same capability-selection; only the type name moved so the protocol can take the §C1 name verbatim.
public struct ModelCatalog: Sendable {

    /// All known descriptors, default first.
    public let models: [ModelDescriptor]

    /// The id used when a command does not pin a specific model. Configurable so 31B ↔ 26B-A4B is a
    /// one-line switch (tasks.md 4.3).
    public var defaultModelID: String

    public init(models: [ModelDescriptor], defaultModelID: String) {
        self.models = models
        self.defaultModelID = defaultModelID
    }

    /// The built-in registry of Gemma 4 entries.
    ///
    /// Ids are STABLE (`gemma-4-31b` / `gemma-4-26b-a4b` / `gemma-4-12b`) — they are the on-disk
    /// folder name and the routing key the `GemmaRuntime` factory maps to a `Gemma4Pipeline.Model`.
    /// The display names, sizes, and download URLs reflect the real mlx-community 4-bit weights that
    /// `Gemma4Pipeline` downloads from the HuggingFace Hub:
    ///   - 31B 4-bit  → `mlx-community/gemma-4-31b-it-4bit`     (~17 GB)
    ///   - 26B-A4B    → `mlx-community/gemma-4-26b-a4b-it-4bit` (~14 GB)
    ///   - E4B 4-bit  → `mlx-community/gemma-4-e4b-it-4bit`     (~5 GB, the any-to-any model carrying
    ///                  the reserved `.audio` capability)
    /// `integritySHA` is a sentinel: the real provisioner delegates download + integrity to the
    /// pipeline / HF Hub (which verify), so the manager's byte-SHA path is bypassed for the real
    /// runtime (see `ModelManager.ModelProvisioner`).
    public static let standard = ModelCatalog(
        models: [
            ModelDescriptor(
                id: "gemma-4-31b",
                displayName: "Gemma 4 31B (text + vision, 4-bit)",
                sizeBytes: 17 * 1024 * 1024 * 1024, // ~17 GB at 4-bit
                integritySHA: "hub-verified",
                downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-31b-it-4bit")!,
                capabilities: [.text, .vision],
                quantization: .qat4bit,
                maxContextTokens: 131_072
            ),
            ModelDescriptor(
                id: "gemma-4-26b-a4b",
                displayName: "Gemma 4 26B-A4B (faster MoE, text + vision, 4-bit)",
                sizeBytes: 14 * 1024 * 1024 * 1024, // ~14 GB at 4-bit
                integritySHA: "hub-verified",
                downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-4bit")!,
                capabilities: [.text, .vision],
                quantization: .qat4bit,
                maxContextTokens: 131_072
            ),
            ModelDescriptor(
                id: "gemma-4-12b",
                displayName: "Gemma 4 E4B (compact, text + vision + audio, 4-bit)",
                sizeBytes: 5 * 1024 * 1024 * 1024, // ~5 GB at 4-bit
                integritySHA: "hub-verified",
                downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit")!,
                capabilities: [.text, .vision, .audio],
                quantization: .qat4bit,
                maxContextTokens: 32_768
            )
        ],
        defaultModelID: "gemma-4-31b"
    )

    /// Look up a descriptor by id.
    public func descriptor(id: String) -> ModelDescriptor? {
        models.first { $0.id == id }
    }

    /// The configured default descriptor (must exist in `models`).
    public var defaultDescriptor: ModelDescriptor? {
        descriptor(id: defaultModelID)
    }

    /// Capability-based selection: the best descriptor that satisfies ALL required capabilities, or a
    /// clear failure when none does.
    ///
    /// Preference order: the configured default first (if it qualifies), then `models` order — which
    /// is curated quality-first (31B before 26B-A4B before 12B). A vision command therefore selects a
    /// vision-capable model; an audio command selects the (reserved) 12B; an impossible requirement
    /// throws `RuntimeError.unavailable` rather than silently returning a lesser model.
    public func selectModel(requiring required: Set<Modality>) throws -> ModelDescriptor {
        let candidates = models.filter { required.isSubset(of: $0.capabilities) }
        guard !candidates.isEmpty else {
            let names = required.map(\.rawValue).sorted().joined(separator: ", ")
            throw RuntimeError.unavailable(reason: "No registered model satisfies required capabilities: [\(names)]")
        }
        // Prefer the configured default when it qualifies; else the first (quality-first) candidate.
        if let def = defaultDescriptor, candidates.contains(def) {
            return def
        }
        return candidates[0]
    }
}
