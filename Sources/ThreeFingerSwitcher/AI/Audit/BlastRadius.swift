import Foundation

/// The blast-radius classification of a tool/sink (`ai-background-autonomy`, Wave 4, design Decision 2).
/// This slice OWNS only resolution / whitelist / audit / escalation — `WritePolicyTier` and
/// `ToolDescriptor` are OWNED by `ai-tool-routing` (integration fix C1) and CONSUMED here verbatim
/// (never redefined). MLX-free Core (`swift test`-verified).
///
/// The three blast-radius tiers are the *conceptual* classification; they collapse onto the existing
/// `WritePolicyTier` (`auto`/`confirm`/`dangerous`) so no new descriptor enum is born:
/// - `.contained` — the app's own stores (agent memory, project notes) + read-only retrieval; the
///   descriptor ships `.auto` and runs in the background even when parked (still audited).
/// - `.external` — touches the user's wider world but bounded (calendar / contacts / launch / send);
///   the descriptor ships `.confirm`, lowerable to `.auto` only by a whitelist match.
/// - `.dangerous` — delete / overwrite-existing / arbitrary-shell / off-list / Claude-handoff cost; the
///   descriptor ships `.dangerous` and is foreground-only (never lowered by the whitelist).
public enum BlastRadius: Equatable, Sendable {
    /// The app's own stores; descriptor ships `.auto`.
    case contained
    /// Touches the user's world but bounded (calendar / contacts / launch / send).
    case external
    /// Delete / overwrite-existing / arbitrary-shell / off-list / handoff-cost.
    case dangerous

    /// The stable CONTAINED name-prefix set OWNED here (design Decision 2) so the policy layer recognizes
    /// the app's own stores WITHOUT importing the memory slice. A descriptor whose name begins with one of
    /// these AND that ships `.auto` is `.contained`. Read-only retrieval (`retrieve`/`widen_candidates`)
    /// is contained-by-read.
    public static let containedNamePrefixes: [String] = [
        "memory.",
        "save_to_project",
        "retrieve",
        "widen_candidates",
    ]

    /// Whether a tool name names one of the app's own (CONTAINED) stores / read-only retrieval.
    public static func isContainedName(_ name: String) -> Bool {
        containedNamePrefixes.contains { name.hasPrefix($0) }
    }

    /// The pure descriptor → blast-radius classifier (design Decision 2). Reads the descriptor's stable
    /// `name` + `writePolicy`:
    /// - `.dangerous` → `.dangerous` (unconditional; the name is ignored — danger is intrinsic).
    /// - a CONTAINED name → `.contained`.
    /// - otherwise → `.external`.
    ///
    /// Defensive: a `.auto` descriptor whose name is NOT in the CONTAINED set is treated as `.external`
    /// (a non-contained tool should never ship `.auto`) and flagged in debug — the CONTAINED set is the
    /// authority, an accidental `.auto` is never silently trusted.
    public static func of(_ descriptor: ToolDescriptor) -> BlastRadius {
        if descriptor.writePolicy == .dangerous { return .dangerous }
        if isContainedName(descriptor.name) { return .contained }
        if descriptor.writePolicy == .auto {
            assertionFailure("Non-contained tool '\(descriptor.name)' ships .auto — treated as .external (CONTAINED set is the authority).")
            return .external
        }
        return .external
    }
}
