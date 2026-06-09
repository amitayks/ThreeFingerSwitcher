import Foundation

/// A description of one known model: enough to download it, verify it, and route commands to it by
/// capability. The registry keeps model/runtime version churn off the feature code (design D1, the
/// "registry drives upgrades" scenario): a newer entry becomes selectable via configuration, not a
/// code change in the band/executor/tasks.
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
    /// What this model can serve. A vision command requires `.vision`; `.audio` is reserved.
    public var capabilities: Set<Modality>
    /// Quantization scheme of the published weights (informational + selection tie-breaks later).
    public var quantization: Quantization

    public enum Quantization: String, Codable, Sendable {
        case qat4bit   // QAT 4-bit (the shipped default for Apple Silicon)
        case int8
        case bf16
    }

    public init(id: String,
                displayName: String,
                sizeBytes: Int64,
                integritySHA: String,
                downloadURL: URL,
                capabilities: Set<Modality>,
                quantization: Quantization) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.integritySHA = integritySHA
        self.downloadURL = downloadURL
        self.capabilities = capabilities
        self.quantization = quantization
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
public struct ModelRegistry: Sendable {

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
    public static let standard = ModelRegistry(
        models: [
            ModelDescriptor(
                id: "gemma-4-31b",
                displayName: "Gemma 4 31B (text + vision, 4-bit)",
                sizeBytes: 17 * 1024 * 1024 * 1024, // ~17 GB at 4-bit
                integritySHA: "hub-verified",
                downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-31b-it-4bit")!,
                capabilities: [.text, .vision],
                quantization: .qat4bit
            ),
            ModelDescriptor(
                id: "gemma-4-26b-a4b",
                displayName: "Gemma 4 26B-A4B (faster MoE, text + vision, 4-bit)",
                sizeBytes: 14 * 1024 * 1024 * 1024, // ~14 GB at 4-bit
                integritySHA: "hub-verified",
                downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-4bit")!,
                capabilities: [.text, .vision],
                quantization: .qat4bit
            ),
            ModelDescriptor(
                id: "gemma-4-12b",
                displayName: "Gemma 4 E4B (compact, text + vision + audio, 4-bit)",
                sizeBytes: 5 * 1024 * 1024 * 1024, // ~5 GB at 4-bit
                integritySHA: "hub-verified",
                downloadURL: URL(string: "https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit")!,
                capabilities: [.text, .vision, .audio],
                quantization: .qat4bit
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
