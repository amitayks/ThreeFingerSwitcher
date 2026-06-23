import Foundation

/// The INJECTED context-budget seam (design D6, integration fix C3). The executor's compaction logic
/// depends on THIS protocol, NEVER on the concrete `agentContextTokens` user slider — so this slice
/// (`ai-conversation-runtime`) builds and runs without `ai-batched-runtime-and-context` landing first.
///
/// The app wires a real provider backed by `ModelDescriptor.maxContextTokens` ∩ the user's
/// `agentContextTokens` (both owned by `ai-batched-runtime-and-context`); tests pass a fixed-budget stub;
/// this slice ships `DefaultContextBudget` as a standalone constant fallback.
public protocol ContextBudgetProviding: Sendable {
    /// The maximum number of tokens the assembled context for a turn may occupy.
    var maxContextTokens: Int { get }
}

/// A standalone constant budget so this slice builds + runs before the real provider exists. The default
/// is a conservative Gemma-class context; the real model max is supplied later through this same seam.
public struct DefaultContextBudget: ContextBudgetProviding {
    public let maxContextTokens: Int
    public init(maxContextTokens: Int = 8192) {
        self.maxContextTokens = maxContextTokens
    }
}

/// A pure, deterministic estimate of an `[AgentMessage]`'s token cost. Honest about being an estimate
/// (a character/token ratio, not a real tokenizer) — which is why compaction keeps a safety margin
/// (`ConversationCompactor.marginFraction`) and compacts BELOW the budget rather than at it. Estimates
/// `text` ONLY (never `thinking`), since thinking is never re-fed.
public enum TokenEstimator {

    /// Rough characters-per-token ratio for a Gemma-class tokenizer. Deliberately low (so we
    /// over-estimate and compact early) rather than risk an overflow.
    static let charsPerToken = 4

    /// Estimate the token cost of a single string (its committed text).
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / charsPerToken)
    }

    /// Estimate the token cost of a message list, reading committed `text` only (never `thinking`).
    public static func estimate(_ messages: [AgentMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1.text) }
    }
}
