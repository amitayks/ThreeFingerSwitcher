import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for context compaction (`ai-conversation-runtime`, tasks §4) — the pure windowing decision
/// (`needsCompaction`/`plan`/`applied`) against an injected fixed budget, the summarization model call,
/// the load-bearing guarantee that thinking never enters the summary input, and the end-to-end shape:
/// a compacted conversation assembles with the summary as a `system` prefix and the dropped raw turns
/// gone.
final class ConversationCompactionTests: XCTestCase {

    /// A fixed-budget provider so the windowing decision is deterministic (integration fix C3: the
    /// executor reads the budget through this seam, never a concrete user slider).
    private struct FixedBudget: ContextBudgetProviding {
        let maxContextTokens: Int
    }

    private func conversation(_ messages: [AgentMessage], summary: String? = nil) -> AgentConversation {
        AgentConversation(title: "t", messages: messages, compactedSummary: summary)
    }

    // MARK: - TokenEstimator

    func testEstimateGrowsWithContentAndIgnoresEmpty() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0, "empty text costs nothing")
        let short = TokenEstimator.estimate("hello")
        let long = TokenEstimator.estimate(String(repeating: "hello ", count: 100))
        XCTAssertGreaterThan(long, short, "the estimate grows with content length")
        // Estimates committed text only — a message's thinking does not affect the estimate.
        let withThinking = AgentMessage(role: .assistant, text: "hi", thinking: String(repeating: "x", count: 1000))
        XCTAssertEqual(TokenEstimator.estimate([withThinking]), TokenEstimator.estimate("hi"),
                       "the estimator reads committed text only, never thinking")
    }

    // MARK: - needsCompaction (injected budget)

    func testNeedsCompactionTrueOnlyOverTheMarginAdjustedBudget() {
        let small = conversation([AgentMessage(role: .user, text: "short")])
        XCTAssertFalse(ConversationCompactor.needsCompaction(small, budget: FixedBudget(maxContextTokens: 1000)),
                       "a short thread under budget does not compact")

        let bigText = String(repeating: "word ", count: 500)   // ~625 estimated tokens
        let big = conversation([AgentMessage(role: .user, text: bigText)])
        XCTAssertTrue(ConversationCompactor.needsCompaction(big, budget: FixedBudget(maxContextTokens: 100)),
                      "a thread whose estimate crosses the margin-adjusted budget compacts")
    }

    // MARK: - plan: keep recent N, collapse the older prefix (incl. a prior summary)

    func testPlanKeepsRecentTurnsAndFoldsPriorSummary() {
        let msgs = (0..<10).map { AgentMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "m\($0)") }
        let convo = conversation(msgs, summary: "PRIOR-SUMMARY")
        let plan = ConversationCompactor.plan(convo, keepRecentTurns: 3)

        XCTAssertEqual(plan.keptTail.map(\.text), ["m7", "m8", "m9"], "the most recent 3 are kept verbatim")
        XCTAssertEqual(plan.toSummarize.map(\.text), (0..<7).map { "m\($0)" }, "the older 7 are collapsed")
        XCTAssertEqual(plan.priorSummary, "PRIOR-SUMMARY", "the prior summary is folded into the new summary's input")
        XCTAssertFalse(plan.isEmpty)
    }

    func testPlanIsEmptyWhenNothingOlderThanTheKeptTail() {
        let msgs = [AgentMessage(role: .user, text: "a"), AgentMessage(role: .assistant, text: "b")]
        let plan = ConversationCompactor.plan(conversation(msgs), keepRecentTurns: 6)
        XCTAssertTrue(plan.isEmpty, "nothing to collapse when the thread is at/below the kept-tail size")
    }

    // MARK: - summarize: a model call over committed text only

    func testSummarizeProducesScriptedSummary() async throws {
        let runtime = StubLLMRuntime(scriptedTokens: ["A concise summary."], interTokenDelayNanos: 0)
        let plan = ConversationCompactor.plan(
            conversation((0..<8).map { AgentMessage(role: .user, text: "m\($0)") }),
            keepRecentTurns: 2)
        let summary = try await ConversationCompactor.summarize(plan, runtime: runtime)
        XCTAssertEqual(summary, "A concise summary.", "summarize returns the model's response")
    }

    func testSummarizeInputExcludesThinking() async throws {
        // An echoing stub (empty scriptedTokens) returns its prompt as the "summary", so we can inspect
        // exactly what was fed to the model.
        let runtime = StubLLMRuntime(scriptedTokens: [], interTokenDelayNanos: 0)
        let toSummarize = [
            AgentMessage(role: .user, text: "VISIBLE-USER-TEXT"),
            AgentMessage(role: .assistant, text: "VISIBLE-ANSWER", thinking: "SECRET-REASONING"),
        ]
        let plan = CompactionPlan(toSummarize: toSummarize, keptTail: [], priorSummary: "OLD-SUMMARY")
        let echoedPrompt = try await ConversationCompactor.summarize(plan, runtime: runtime)

        XCTAssertTrue(echoedPrompt.contains("VISIBLE-USER-TEXT"), "committed user text is summarized")
        XCTAssertTrue(echoedPrompt.contains("VISIBLE-ANSWER"), "committed answer text is summarized")
        XCTAssertTrue(echoedPrompt.contains("OLD-SUMMARY"), "a prior summary is folded into the input")
        XCTAssertFalse(echoedPrompt.contains("SECRET-REASONING"),
                       "thinking is NEVER part of the summarization input")
    }

    func testSummarizePropagatesRuntimeError() async {
        let runtime = StubLLMRuntime(scriptedTurns: [.init(error: .serverUnavailable)], interTokenDelayNanos: 0)
        let plan = CompactionPlan(toSummarize: [AgentMessage(role: .user, text: "x")], keptTail: [], priorSummary: nil)
        do {
            _ = try await ConversationCompactor.summarize(plan, runtime: runtime)
            XCTFail("summarize should propagate the runtime error so the caller can fail the turn")
        } catch let error as RuntimeError {
            XCTAssertEqual(error, .serverUnavailable)
        } catch {
            XCTFail("expected a RuntimeError, got \(error)")
        }
    }

    // MARK: - applied + assembly: the summary becomes a system prefix, dropped turns are gone

    func testAppliedReplacesDroppedTurnsAndAssemblesAsSystemPrefix() {
        let msgs = (0..<8).map { AgentMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "OLD\($0)") }
            + [AgentMessage(role: .user, text: "RECENT")]
        let convo = conversation(msgs)
        let plan = ConversationCompactor.plan(convo, keepRecentTurns: 1)
        let compacted = ConversationCompactor.applied(plan, summary: "THE-SUMMARY", to: convo,
                                                      now: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(compacted.messages.map(\.text), ["RECENT"], "only the recent tail survives in messages")
        XCTAssertEqual(compacted.compactedSummary, "THE-SUMMARY", "the summary becomes the prefix")

        // Assemble the way the executor does: prefix the summary as a synthetic system message.
        var assembled: [AgentMessage] = []
        if let s = compacted.compactedSummary { assembled.append(AgentMessage(role: .system, text: s)) }
        assembled.append(contentsOf: compacted.messages)
        let prompt = ChatTemplate.flatten(assembled)

        XCTAssertTrue(prompt.contains("System: THE-SUMMARY"), "the summary rides as a system prefix")
        XCTAssertTrue(prompt.contains("User: RECENT"), "the kept tail is present")
        XCTAssertFalse(prompt.contains("OLD0"), "the dropped raw turns are gone from the assembled context")
    }
}
