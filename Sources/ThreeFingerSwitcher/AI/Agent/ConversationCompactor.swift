import Foundation

/// Context compaction (design D6) — this slice OWNS it. A long thread will exceed the model's context
/// window; when the assembled-context estimate approaches the budget, the older turns collapse into a
/// single compact summary (a model call) so the conversation can continue without overflow, and so
/// `.thinking` never bloats the window (the summary input reads committed `text` only).
///
/// Split into a PURE decision (`needsCompaction`/`plan`/`applied`) and an IMPURE pass (`summarize`, a
/// single `LLMRuntime` call). The decision is deterministic and unit-testable against a fixed-budget
/// `ContextBudgetProviding` stub.

/// The plan for one compaction: which prefix to collapse, which recent tail to keep verbatim, and the
/// prior summary (if any) that is folded INTO the new summary's input (not kept separately).
public struct CompactionPlan: Equatable, Sendable {
    /// The older messages to collapse into the new summary (their committed text is the summary input).
    public var toSummarize: [AgentMessage]
    /// The most-recent messages kept verbatim.
    public var keptTail: [AgentMessage]
    /// Any existing summary, folded into the new summary's input so it is not lost.
    public var priorSummary: String?

    public init(toSummarize: [AgentMessage], keptTail: [AgentMessage], priorSummary: String?) {
        self.toSummarize = toSummarize
        self.keptTail = keptTail
        self.priorSummary = priorSummary
    }

    /// Nothing to collapse (e.g. the thread is already at/below the kept-tail size).
    public var isEmpty: Bool { toSummarize.isEmpty }
}

public enum ConversationCompactor {

    /// Compact BELOW the budget, not at it — the estimator is approximate, so leave headroom.
    public static let marginFraction = 0.8

    /// The number of most-recent messages kept verbatim through a compaction (tuning constant — its
    /// final value is a run-verify decision on the M5 build; the windowing logic is independent of it).
    public static let keepRecentTurns = 6

    /// The margin-adjusted threshold at which compaction triggers.
    static func threshold(_ maxContextTokens: Int) -> Int {
        Int(Double(maxContextTokens) * marginFraction)
    }

    /// The estimated assembled-context cost of a conversation: its messages' committed text plus any
    /// existing summary prefix (both re-fed; thinking is excluded by construction).
    public static func assembledEstimate(_ conversation: AgentConversation) -> Int {
        TokenEstimator.estimate(conversation.messages)
            + (conversation.compactedSummary.map(TokenEstimator.estimate) ?? 0)
    }

    /// PURE: true when the assembled estimate (incl. an existing summary) crosses the margin-adjusted
    /// budget read through the injected provider.
    public static func needsCompaction(_ conversation: AgentConversation,
                                       budget: ContextBudgetProviding) -> Bool {
        assembledEstimate(conversation) > threshold(budget.maxContextTokens)
    }

    /// PURE: keep the most-recent `keepRecentTurns` messages verbatim; collapse everything older — and
    /// any prior summary — into the to-summarize input. Deterministic and budget-agnostic in its
    /// windowing (the budget decides WHETHER to compact, not the window shape).
    public static func plan(_ conversation: AgentConversation,
                            keepRecentTurns: Int = keepRecentTurns) -> CompactionPlan {
        let messages = conversation.messages
        let keep = min(max(0, keepRecentTurns), messages.count)
        let keptTail = Array(messages.suffix(keep))
        let toSummarize = Array(messages.prefix(messages.count - keep))
        return CompactionPlan(toSummarize: toSummarize,
                              keptTail: keptTail,
                              priorSummary: conversation.compactedSummary)
    }

    /// IMPURE: a single `runtime.generate` call (reasoning OFF) condensing the to-summarize slice — and
    /// the prior summary — into a compact factual summary. The summary input reads committed `text` ONLY
    /// (never `thinking`). Errors propagate as `RuntimeError` (the caller maps them via `AIError`); a
    /// failure here MUST NOT drop history (the caller applies the plan only on success).
    public static func summarize(_ plan: CompactionPlan, runtime: LLMRuntime) async throws -> String {
        let priorPart = plan.priorSummary.map { "Previous summary:\n\($0)\n\n" } ?? ""
        let transcript = plan.toSummarize
            .map { "\($0.role.rawValue): \($0.text)" }   // committed text only — never `thinking`
            .joined(separator: "\n")
        let prompt = """
        Condense the following conversation excerpt into a concise factual summary that preserves the key \
        facts, decisions, names, and context needed to continue the conversation. Output only the summary.

        \(priorPart)\(transcript)
        """
        return try await runtime.generateText(LLMRequest(prompt: prompt, reasoning: false))
    }

    /// PURE: apply a completed compaction — set the summary as the new prefix and drop the collapsed
    /// turns, keeping only the recent tail. Called by the executor ONLY after `summarize` succeeds.
    public static func applied(_ plan: CompactionPlan,
                               summary: String,
                               to conversation: AgentConversation,
                               now: Date = Date()) -> AgentConversation {
        var updated = conversation
        updated.compactedSummary = summary
        updated.messages = plan.keptTail
        updated.updatedAt = now
        return updated
    }
}
