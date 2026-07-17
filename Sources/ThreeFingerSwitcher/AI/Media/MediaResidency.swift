import Foundation

/// Honest residency (design D9, §3.4) — a heavy gen EVICTS chat ("busy painting"), surfaced not hidden.
/// The sink consults the `ModelRegistry` (`ensureResident` for the image/video runtime) BEFORE driving the
/// generation. When residency math (owned by `ai-model-fleet`, consumed here) decides the gen must evict
/// the chat model, the canvas/rail surface a calm "the assistant is busy painting" state rather than
/// pretending co-residency; chat resumes when the gen finishes / parks.
///
/// The slice does NOT own the eviction math — it asks the registry to make room and OBSERVES whether chat
/// is still resident afterwards. MLX-free Core (orchestration over the injected registry).
public struct MediaResidencyCoordinator: Sendable {
    private let registry: ModelRegistry
    /// The `ModelRole` whose presence means "chat is resident". Eviction of it → busy-painting.
    private let chatRole: ModelRole

    public init(registry: ModelRegistry, chatRole: ModelRole = .chat) {
        self.registry = registry
        self.chatRole = chatRole
    }

    /// Make room for `modelID` (the image/video runtime). Returns the resulting residency note:
    ///  - `.coResident`   — the gen fits alongside chat (e.g. Q4 image), chat stays available;
    ///  - `.busyPainting` — admitting the gen EVICTED chat; surface the calm busy state, chat resumes after.
    /// Throws (mapped at the sink) when the target can't be admitted even after evicting everything
    /// (`FleetError.cannotAdmit`) — a clean `.failed`, never a hang.
    public func ensureRoom(for modelID: String) async throws -> MediaResidencyNote {
        let chatResidentBefore = isChatResident()
        try await registry.ensureResident(modelID)
        let chatResidentAfter = isChatResident()
        // If chat was resident and is now gone, the gen evicted it → busy painting.
        if chatResidentBefore && !chatResidentAfter { return .busyPainting }
        return .coResident
    }

    private func isChatResident() -> Bool {
        registry.resident().contains { $0.role == chatRole }
    }
}

/// The residency outcome the canvas/rail surface (design D9).
public enum MediaResidencyNote: Equatable, Sendable {
    /// The gen co-resides with chat (chat stays available).
    case coResident
    /// The gen evicted chat — surface "the assistant is busy painting"; chat resumes on finish/park.
    case busyPainting

    /// The calm, honest user-facing line for a busy-painting state (never a hang, never silence).
    public var busyHeadline: String? {
        switch self {
        case .busyPainting: return "The assistant is busy painting. Chat resumes when it's done."
        case .coResident:   return nil
        }
    }
}
