import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for subagents as routable tools (`refactor-park-and-background-agents` / `ai-subagents`):
/// registered templates are invocable as `subagent:<name>` steps, the sub-task runs in a FRESH
/// conversation (none of the orchestrator's history), ONLY the summary re-enters the orchestrator
/// thread, cancellation rides the turn, and a failure is a clean failed step. MLX-free, stub-driven.
final class SubagentToolContributorTests: XCTestCase {

    /// A chat runtime that records every request it serves (so isolation is assertable) and streams a
    /// scripted response — or throws a scripted error.
    private final class RecordingRuntime: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        private(set) var servedPrompts: [String] = []
        private let response: [String]
        private let error: RuntimeError?
        private let lock = NSLock()
        init(response: [String], error: RuntimeError? = nil) {
            self.response = response
            self.error = error
        }
        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            lock.lock(); servedPrompts.append(request.prompt); lock.unlock()
            let toks = response, err = error
            return AsyncThrowingStream { c in
                if let err { c.finish(throwing: err); return }
                for (i, t) in toks.enumerated() { c.yield(Token(t, isFinal: i == toks.count - 1)) }
                c.finish()
            }
        }
        func structured<T: Decodable & Sendable>(_ r: LLMRequest, schema: StructuredSchema,
                                                 as type: T.Type) async throws -> StructuredOutcome<T> {
            throw RuntimeError.serverUnavailable   // subagents are prompt-only; never routed internally
        }
    }

    private func summarizeCall(input: String? = "long text to condense",
                               userText: String = "please summarize") -> RoutedCall {
        let descriptor = Subagent.builtIns[0].toolDescriptor
        let args = input.map { "{\"input\":\"\($0)\"}" } ?? "{}"
        return RoutedCall(descriptor: descriptor,
                          route: ToolRoute(tool: descriptor.name, argumentsJSON: args),
                          userText: userText, source: TaskSource())
    }

    func testBuiltInsAreRegisteredAsRoutableTools() {
        let contributor = SubagentToolContributor(templates: Subagent.builtIns,
                                                  runtimeProvider: { RecordingRuntime(response: ["x"]) })
        let names = contributor.descriptors().map(\.name)
        XCTAssertEqual(names, ["subagent:summarize", "subagent:draft"])
        XCTAssertTrue(contributor.canHandle("subagent:summarize"))
        XCTAssertFalse(contributor.canHandle("subagent:invented"),
                       "only REGISTERED templates are invocable — no model-invented subagents")
        XCTAssertTrue(contributor.descriptors().allSatisfy { $0.writePolicy == .auto },
                      "a subagent is CONTAINED (read-only to the orchestrator's world)")
    }

    func testRunsInFreshConversationAndReturnsOnlyTheSummary() async {
        let runtime = RecordingRuntime(response: ["the ", "gist"])
        let contributor = SubagentToolContributor(templates: Subagent.builtIns,
                                                  runtimeProvider: { runtime })
        let result = await contributor.run(summarizeCall(), gate: AutoApproveGate())

        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.summary, "the gist", "ONLY the final text re-enters the orchestrator")

        let served = runtime.servedPrompts.joined()
        XCTAssertTrue(served.contains("long text to condense"), "the routed input seeds the sub-task")
        XCTAssertFalse(served.contains("please summarize"),
                       "the orchestrator's history is NOT visible to the subagent (fresh context)")
    }

    func testEmptyRoutedArgsFallBackToTheUserText() async {
        let runtime = RecordingRuntime(response: ["ok"])
        let contributor = SubagentToolContributor(templates: Subagent.builtIns,
                                                  runtimeProvider: { runtime })
        _ = await contributor.run(summarizeCall(input: nil, userText: "the actual ask"),
                                  gate: AutoApproveGate())
        XCTAssertTrue(runtimeServed(runtime, contains: "the actual ask"))
    }

    func testFailureIsACleanFailedStepNeverAFabricatedSummary() async {
        let contributor = SubagentToolContributor(
            templates: Subagent.builtIns,
            runtimeProvider: { RecordingRuntime(response: [], error: .serverUnavailable) })
        let result = await contributor.run(summarizeCall(), gate: AutoApproveGate())
        guard case let .failed(headline) = result.status else {
            return XCTFail("expected a failed step, got \(result.status)")
        }
        XCTAssertEqual(headline, AIError.message(for: RuntimeError.serverUnavailable).headline,
                       "the failure carries the clean translated headline")
        XCTAssertTrue(result.summary.isEmpty, "no fabricated summary rides a failure")
    }

    func testCancellationResolvesAsTheLoopCancelSentinelNotAFailure() async {
        let contributor = SubagentToolContributor(
            templates: Subagent.builtIns,
            runtimeProvider: { RecordingRuntime(response: [], error: .cancelled) })
        let result = await contributor.run(summarizeCall(), gate: AutoApproveGate())
        XCTAssertEqual(result.status, .declined(reason: TaskKindToolContributor.cancelledReason),
                       "a cancelled subagent stops the loop quietly (a discard, never a failure)")
    }

    /// End-to-end: the loop routes a `subagent:summarize` step and the summary re-enters the
    /// orchestrator context as ONE tool message; the loop then answers over it.
    func testLoopRoutesSubagentStepAndAbsorbsOnlyTheSummary() async {
        let subagentRuntime = RecordingRuntime(response: ["condensed"])
        let contributor = SubagentToolContributor(templates: Subagent.builtIns,
                                                  runtimeProvider: { subagentRuntime })
        let registry = ToolRegistry([contributor])
        let loopRuntime = ScriptedLoopRuntime(
            routes: ["{\"tool\":\"subagent:summarize\",\"argumentsJSON\":\"{\\\"input\\\":\\\"stuff\\\"}\"}",
                     "{\"tool\":\"\"}"],
            answer: ["final answer"])
        let loop = AgentLoop(runtime: loopRuntime, registry: registry,
                             candidateSource: KeywordToolCandidateSource(all: { registry.allDescriptors() }),
                             gate: AutoApproveGate())
        let result = await loop.run(context: RouteContext(messages: [AgentMessage(role: .user, text: "summarize stuff")]))
        XCTAssertEqual(result.outcome, .answered(text: "final answer"))
        XCTAssertEqual(result.steps.map(\.summary), ["condensed"],
                       "exactly one tool message — the summary — re-entered the orchestrator")
    }

    private func runtimeServed(_ runtime: RecordingRuntime, contains needle: String) -> Bool {
        runtime.servedPrompts.joined().contains(needle)
    }

    /// The orchestrator-side runtime for the end-to-end test: scripted routes + a final answer.
    private final class ScriptedLoopRuntime: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        private var routes: [String]
        private let answerTokens: [String]
        private let lock = NSLock()
        init(routes: [String], answer: [String]) { self.routes = routes; self.answerTokens = answer }
        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            let toks = answerTokens
            return AsyncThrowingStream { c in
                for (i, t) in toks.enumerated() { c.yield(Token(t, isFinal: i == toks.count - 1)) }
                c.finish()
            }
        }
        func structured<T: Decodable & Sendable>(_ r: LLMRequest, schema: StructuredSchema,
                                                 as type: T.Type) async throws -> StructuredOutcome<T> {
            let json: String = {
                lock.lock(); defer { lock.unlock() }
                return routes.isEmpty ? "{\"tool\":\"\"}" : routes.removeFirst()
            }()
            return .value(try JSONDecoder().decode(T.self, from: Data(json.utf8)))
        }
    }
}
