import Foundation

// MARK: - Full Potential gate (MLX-free Core)
//
// The single source of truth for "is heavy AI capability X actually unlocked." V2.5 evolves the
// on-device agent into a two-lane, multi-model, media-generating fleet (see
// `docs/ai-agent-v2-addendum-compute-media-fleet.md` §D1) — but the project ships **calm**: every
// heavy capability is OFF until the user performs one deliberate act ("Release Full Potential") and
// then opts into the specific capability, cost disclosed in the same breath.
//
// This file owns the master gate's *gating logic only* — a pure, total `Bool` resolver every heavy
// slice consults before activating. It does NOT redefine sibling-owned types (`ComputeLane`/
// `LaneRouting` §A1, `MediaRuntime` §B1, `ModelRegistry`/`ModelDescriptor` §C1, `WritePolicyTier`):
// the enum below only NAMES the capabilities the flags gate. The persisted flags live in
// `AppSettings`; the adapter (`AppSettings.fullPotentialGate`) maps them into the gate's input.

/// The five heavy AI capabilities the Full Potential flags gate, one case per sub-flag (addendum §D1).
/// `CaseIterable` so the Hub renders the five rows by iterating and a test can assert every case is
/// gated; `Codable`/`Sendable` so it can ride any persistence or cross-actor boundary. The `rawValue`
/// strings are stable identifiers (do not rename — they may key UI/telemetry).
public enum FullPotentialCapability: String, CaseIterable, Codable, Sendable {
    /// The CPU ternary lane (`ai-compute-tiers` → `cpuLaneEnabled`).
    case cpuLane
    /// The K-stream GPU batched runtime + growable context (`ai-batched-runtime-and-context` →
    /// `batchedRuntimeEnabled`).
    case batchedRuntime
    /// Image/video generation tools (`ai-media-runtime` + backends → `mediaGenEnabled`).
    case mediaGen
    /// Parked auto-vs-escalate + whitelist + audit (`ai-background-autonomy` → `backgroundAutonomyEnabled`).
    case backgroundAutonomy
    /// Cloud fleet members — Claude / GLM-5.2 (`ai-model-fleet` cloud members → `fleetCloudEscalationEnabled`).
    case fleetCloud
}

/// The gate's pure input: the AI-commands opt-in, the master, and the five per-capability sub-flags.
/// A plain value type (`Equatable`/`Sendable`) assembled from `AppSettings` by the adapter; the gate
/// reads it, never mutates it (turning the master off RELOCKS by computation, RETAINING the stored
/// sub-flag values — design Decision 2).
public struct FullPotentialFlags: Equatable, Sendable {
    /// The existing AI feature opt-in (`AppSettings.aiCommandsEnabled`). The fleet is a strict subset
    /// of the AI feature — if this is off there is no resident model at all, so every fleet capability
    /// is meaningless and locked.
    public var aiCommandsEnabled: Bool
    /// The master "Release Full Potential" gate (`fullPotentialEnabled`). Off ⇒ every capability locked
    /// (the calm panic-off).
    public var fullPotentialEnabled: Bool

    public var cpuLane: Bool
    public var batchedRuntime: Bool
    public var mediaGen: Bool
    public var backgroundAutonomy: Bool
    public var fleetCloud: Bool

    public init(aiCommandsEnabled: Bool,
                fullPotentialEnabled: Bool,
                cpuLane: Bool,
                batchedRuntime: Bool,
                mediaGen: Bool,
                backgroundAutonomy: Bool,
                fleetCloud: Bool) {
        self.aiCommandsEnabled = aiCommandsEnabled
        self.fullPotentialEnabled = fullPotentialEnabled
        self.cpuLane = cpuLane
        self.batchedRuntime = batchedRuntime
        self.mediaGen = mediaGen
        self.backgroundAutonomy = backgroundAutonomy
        self.fleetCloud = fleetCloud
    }
}

/// The pure, total Full Potential resolver. The single boolean check each heavy slice consults before
/// activating: a capability is unlocked **only when** `aiCommandsEnabled ∧ fullPotentialEnabled ∧ its
/// own sub-flag`. No throw, no async, no IO, no model linkage — callable on any thread, in any sink.
public struct FullPotentialGate: Sendable {
    public let flags: FullPotentialFlags

    public init(flags: FullPotentialFlags) {
        self.flags = flags
    }

    /// Resolve whether `capability` is unlocked. Returns `false` (locked) whenever the AI-commands
    /// opt-in is off OR the master is off — closing every gate at once (the calm panic-off) — and
    /// otherwise gates each capability on ONLY its own sub-flag.
    public func isUnlocked(_ capability: FullPotentialCapability) -> Bool {
        // master closed → every capability closed (the calm panic-off); ai-commands closed → likewise
        // (the fleet is a strict subset of the AI feature, which owns the resident model).
        guard flags.aiCommandsEnabled, flags.fullPotentialEnabled else { return false }
        switch capability {
        case .cpuLane:            return flags.cpuLane
        case .batchedRuntime:     return flags.batchedRuntime
        case .mediaGen:           return flags.mediaGen
        case .backgroundAutonomy: return flags.backgroundAutonomy
        case .fleetCloud:         return flags.fleetCloud
        }
    }
}
