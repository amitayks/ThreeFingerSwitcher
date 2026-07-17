import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the model-driven tool-routing slice (`ai-tool-routing`, tasks §2–§6): the `structured()`
/// router's outcome mapping, registry aggregation/dispatch, the bridge into the UNCHANGED task
/// machinery (with the approval gate), candidate ranking, and the bounded route→execute→continue loop
/// (plain-answer, multi-hop, cap, loop-guards, widen, cancel). All driven by scripted fakes — no model.
@MainActor
final class ToolRoutingTests: XCTestCase {

    // MARK: - Fakes

    /// A runtime whose `structured` dequeues scripted route JSON per call and whose `generate` streams a
    /// scripted final answer — so a multi-hop loop is fully deterministic.
    private final class RoutingRuntime: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        private var routes: [String]
        private let answerTokens: [String]
        private let lock = NSLock()
        init(routes: [String], answer: [String] = ["the answer"]) { self.routes = routes; self.answerTokens = answer }

        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            let toks = answerTokens
            return AsyncThrowingStream { c in
                let task = Task {
                    for (i, t) in toks.enumerated() {
                        if Task.isCancelled { c.finish(throwing: RuntimeError.cancelled); return }
                        c.yield(Token(t, isFinal: i == toks.count - 1))
                    }
                    c.finish()
                }
                c.onTermination = { _ in task.cancel() }
            }
        }

        func structured<T: Decodable & Sendable>(_ request: LLMRequest, schema: StructuredSchema,
                                                  as type: T.Type) async throws -> StructuredOutcome<T> {
            let json: String = { lock.lock(); defer { lock.unlock() }; return routes.isEmpty ? "{\"tool\":\"\"}" : routes.removeFirst() }()
            let decoded = try JSONDecoder().decode(T.self, from: Data(json.utf8))
            return .value(decoded)
        }
    }

    /// A contributor returning scripted step results by tool name (loop tests, decoupled from TaskKind).
    private struct FakeContributor: ToolContributor {
        let descriptorsList: [ToolDescriptor]
        var results: [String: ToolStepResult] = [:]
        func descriptors() -> [ToolDescriptor] { descriptorsList }
        func canHandle(_ tool: String) -> Bool { descriptorsList.contains { $0.name == tool } }
        func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
            results[call.descriptor.name]
                ?? ToolStepResult(tool: call.descriptor.name, status: .done, summary: "did \(call.descriptor.name)")
        }
    }

    private final class ScriptedApprovalGate: ApprovalGate, @unchecked Sendable {
        private var decisions: [ApprovalDecision]
        private let lock = NSLock()
        init(_ decisions: [ApprovalDecision] = []) { self.decisions = decisions }
        func awaitDecision(for review: TaskReview) async -> ApprovalDecision {
            lock.lock(); defer { lock.unlock() }
            return decisions.isEmpty ? .approve : decisions.removeFirst()
        }
    }

    /// A fake `TaskDispatching` (bridge tests): returns a scripted review and records executes.
    private final class FakeDispatcher: TaskDispatching {
        var reviewToReturn: TaskReview = .action(title: "Event",
                                                 fields: [ReviewField("Title", "Lunch")],
                                                 payload: .openTool(tool: "x",
                                                                    action: ParsedOpenTool(applicable: true, reason: nil, payload: "p")))
        var executeError: Error?
        private(set) var prepared: [(TaskKind, String)] = []
        private(set) var executed = 0
        func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource, reasoning: Bool) async -> TaskReview {
            prepared.append((kind, resolvedPrompt)); return reviewToReturn
        }
        func execute(_ review: TaskReview) async throws {
            if let executeError { throw executeError }
            executed += 1
        }
    }

    private struct AutoResolver: WritePolicyResolving {
        func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier { .auto }
    }

    private func descriptor(_ name: String, keywords: [String] = [], tier: WritePolicyTier = .confirm) -> ToolDescriptor {
        ToolDescriptor(name: name, summary: "tool \(name)",
                       argsSchema: StructuredSchema(name: name, json: "{\"type\":\"object\"}"),
                       writePolicy: tier, keywords: keywords)
    }

    private func ctx(_ userText: String, allowed: [String] = []) -> RouteContext {
        RouteContext(messages: [AgentMessage(role: .user, text: userText)], allowedTools: allowed)
    }

    // MARK: - Router outcome mapping

    func testRouterPlainAnswerOnEmptyTool() async {
        let rt = StubLLMRuntime(structuredScript: .valid(json: "{\"tool\":\"\"}"))
        let r = await ToolRouter.route(context: ctx("hi"), candidates: [descriptor("add_to_calendar")], runtime: rt, reasoning: false)
        guard case let .route(route) = r else { return XCTFail("expected .route") }
        XCTAssertTrue(route.isPlainAnswer)
    }

    func testRouterRoutesToMatchingCandidate() async {
        let rt = StubLLMRuntime(structuredScript: .valid(json: "{\"tool\":\"add_to_calendar\",\"argumentsJSON\":\"{}\",\"rationale\":\"a meeting\"}"))
        let r = await ToolRouter.route(context: ctx("lunch tomorrow"), candidates: [descriptor("add_to_calendar")], runtime: rt, reasoning: false)
        guard case let .route(route) = r else { return XCTFail("expected .route") }
        XCTAssertEqual(route.tool, "add_to_calendar")
        XCTAssertEqual(route.rationale, "a meeting")
    }

    func testRouterUnknownToolDegradesToPlainAnswer() async {
        let rt = StubLLMRuntime(structuredScript: .valid(json: "{\"tool\":\"nonexistent\"}"))
        let r = await ToolRouter.route(context: ctx("x"), candidates: [descriptor("add_to_calendar")], runtime: rt, reasoning: false)
        guard case let .route(route) = r else { return XCTFail("expected .route") }
        XCTAssertTrue(route.isPlainAnswer, "a tool not in the candidate set degrades to a plain answer, never dispatched")
    }

    func testRouterDeclineIsPlainAnswer() async {
        let rt = StubLLMRuntime(structuredScript: .decline(reason: "no tool fits"))
        let r = await ToolRouter.route(context: ctx("x"), candidates: [descriptor("add_to_calendar")], runtime: rt, reasoning: false)
        guard case let .route(route) = r else { return XCTFail("expected .route") }
        XCTAssertTrue(route.isPlainAnswer, "a decline is the first-class 'just talk' plain answer")
    }

    func testRouterCouldNotProduceValidFallsBackToPlainAnswer() async {
        let rt = StubLLMRuntime(structuredScript: .alwaysInvalid(json: "{}"), maxRepairAttempts: 2) // no "tool" key → exhausts
        let r = await ToolRouter.route(context: ctx("x"), candidates: [descriptor("a")], runtime: rt, reasoning: false)
        guard case let .route(route) = r else { return XCTFail("expected .route, not a failure") }
        XCTAssertTrue(route.isPlainAnswer, "a malformed route is never a fabricated tool call")
    }

    // MARK: - Registry

    func testRegistryAggregatesAndDedupesByNameFirstWins() {
        let a = FakeContributor(descriptorsList: [descriptor("x"), descriptor("y")])
        let b = FakeContributor(descriptorsList: [descriptor("y"), descriptor("z")])
        let registry = ToolRegistry([a, b])
        XCTAssertEqual(registry.allDescriptors().map(\.name), ["x", "y", "z"], "deduped by name, first contributor wins")
    }

    func testRegistryDispatchesToOwningContributorAndUnknownIsDefensiveFailed() async {
        let a = FakeContributor(descriptorsList: [descriptor("x")],
                                results: ["x": ToolStepResult(tool: "x", status: .done, summary: "ran x")])
        let registry = ToolRegistry([a])
        let okCall = RoutedCall(descriptor: descriptor("x"), route: ToolRoute(tool: "x"), userText: "", source: TaskSource())
        let ok = await registry.run(okCall, gate: ScriptedApprovalGate())
        XCTAssertEqual(ok.summary, "ran x")

        let unknownCall = RoutedCall(descriptor: descriptor("ghost"), route: ToolRoute(tool: "ghost"), userText: "", source: TaskSource())
        let unknown = await registry.run(unknownCall, gate: ScriptedApprovalGate())
        guard case .failed = unknown.status else { return XCTFail("an unowned tool returns a defensive .failed") }
    }

    // MARK: - Bridge to the task machinery

    private func bridgeCall(_ kind: TaskKind) -> RoutedCall {
        RoutedCall(descriptor: TaskKindToolContributor.descriptor(for: kind),
                   route: ToolRoute(tool: TaskKindToolContributor.name(for: kind), argumentsJSON: "{}"),
                   userText: "lunch with sam tomorrow", source: TaskSource())
    }

    func testBridgeAutoTierExecutesImmediatelyWithoutGate() async {
        let dispatcher = FakeDispatcher()
        let c = TaskKindToolContributor(dispatcher: dispatcher, resolver: AutoResolver(), kinds: [.addToCalendar])
        let result = await c.run(bridgeCall(.addToCalendar), gate: ScriptedApprovalGate([.skip])) // gate must NOT be consulted
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(dispatcher.executed, 1, "an auto-tier action fires immediately")
    }

    func testBridgeConfirmApproveExecutes() async {
        let dispatcher = FakeDispatcher()
        let c = TaskKindToolContributor(dispatcher: dispatcher, kinds: [.addToCalendar]) // default resolver → .confirm
        let result = await c.run(bridgeCall(.addToCalendar), gate: ScriptedApprovalGate([.approve]))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(dispatcher.executed, 1)
    }

    func testBridgeConfirmSkipDeclinesAndFiresNothing() async {
        let dispatcher = FakeDispatcher()
        let c = TaskKindToolContributor(dispatcher: dispatcher, kinds: [.addToCalendar])
        let result = await c.run(bridgeCall(.addToCalendar), gate: ScriptedApprovalGate([.skip]))
        XCTAssertEqual(result.status, .declined(reason: "skipped"))
        XCTAssertEqual(dispatcher.executed, 0, "a skipped step fires no side effect")
    }

    func testBridgeDeclinedReviewMapsToDeclined() async {
        let dispatcher = FakeDispatcher()
        dispatcher.reviewToReturn = .declined(reason: "not a meeting")
        let c = TaskKindToolContributor(dispatcher: dispatcher, kinds: [.addToCalendar])
        let result = await c.run(bridgeCall(.addToCalendar), gate: ScriptedApprovalGate([.approve]))
        XCTAssertEqual(result.status, .declined(reason: "not a meeting"))
        XCTAssertEqual(dispatcher.executed, 0)
    }

    func testBridgeUnavailableMapsToFailed() async {
        let dispatcher = FakeDispatcher()
        dispatcher.reviewToReturn = .unavailable(reason: "Couldn't produce a valid action.")
        let c = TaskKindToolContributor(dispatcher: dispatcher, kinds: [.addToCalendar])
        let result = await c.run(bridgeCall(.addToCalendar), gate: ScriptedApprovalGate([.approve]))
        XCTAssertEqual(result.status, .failed(headline: "Couldn't produce a valid action."))
    }

    func testBridgeExecuteThrowMapsToFailedNotFalseDone() async {
        let dispatcher = FakeDispatcher()
        dispatcher.executeError = TaskError.calendarPermissionDenied
        let c = TaskKindToolContributor(dispatcher: dispatcher, kinds: [.addToCalendar])
        let result = await c.run(bridgeCall(.addToCalendar), gate: ScriptedApprovalGate([.approve]))
        guard case let .failed(headline) = result.status else { return XCTFail("a thrown sink is .failed, never a false Done") }
        XCTAssertTrue(headline.contains("Calendar"), "the clean TaskError headline, not a raw dump")
    }

    func testBridgeConfiguredTaskBindsConfigInDescriptorName() {
        let save = TaskKindToolContributor.name(for: .saveToProject(project: "Roadmap"))
        XCTAssertEqual(save, "save_to_project:Roadmap", "config is bound in the descriptor identity (Decision Q2)")
        let c = TaskKindToolContributor(dispatcher: FakeDispatcher(), kinds: [.saveToProject(project: "Roadmap")])
        XCTAssertTrue(c.canHandle("save_to_project:Roadmap"))
        XCTAssertFalse(c.canHandle("save_to_project:Other"))
    }

    // MARK: - Candidate retrieval

    func testCandidateRankingPrefersKeywordMatch() {
        let source = KeywordToolCandidateSource(all: [
            descriptor("weather", keywords: ["weather", "forecast"]),
            descriptor("calendar", keywords: ["meeting", "calendar", "schedule"]),
        ])
        let result = source.candidates(for: ctx("schedule a meeting"), limit: 5)
        XCTAssertEqual(result.first?.name, "calendar", "the keyword-matching tool ranks first")
    }

    func testCandidateAlwaysIncludesAllowedTools() {
        let source = KeywordToolCandidateSource(all: [
            descriptor("weather", keywords: ["weather"]),
            descriptor("special", keywords: ["zzz"]),
        ])
        let result = source.candidates(for: ctx("nothing relevant", allowed: ["special"]), limit: 1)
        XCTAssertTrue(result.contains { $0.name == "special" }, "the active skill's allowed tool is always offered")
    }

    func testCandidateRespectsAdditiveCap() {
        let many = (0..<20).map { descriptor("t\($0)") }
        let source = KeywordToolCandidateSource(all: many, additiveCap: 8)
        XCTAssertLessThanOrEqual(source.candidates(for: ctx("x"), limit: 100).count, 8)
    }

    // MARK: - The bounded loop

    private func loop(_ rt: RoutingRuntime, contributor: FakeContributor, gate: ApprovalGate = ScriptedApprovalGate(),
                      maxToolSteps: Int = 8, onThinking: @escaping @Sendable (String) -> Void = { _ in }) -> AgentLoop {
        AgentLoop(runtime: rt, registry: ToolRegistry([contributor]),
                  candidateSource: KeywordToolCandidateSource(all: contributor.descriptorsList),
                  gate: gate, reasoning: false, maxToolSteps: maxToolSteps, onThinking: onThinking)
    }

    func testLoopPlainAnswerOneShotZeroSteps() async {
        let rt = RoutingRuntime(routes: ["{\"tool\":\"\"}"], answer: ["Hello!"])
        let result = await loop(rt, contributor: FakeContributor(descriptorsList: [descriptor("a")])).run(context: ctx("hi"))
        XCTAssertEqual(result.outcome, .answered(text: "Hello!"))
        XCTAssertTrue(result.steps.isEmpty, "a plain answer runs zero tool steps")
    }

    func testLoopSingleToolThenAnswer() async {
        let rt = RoutingRuntime(routes: ["{\"tool\":\"a\",\"argumentsJSON\":\"{}\"}", "{\"tool\":\"\"}"], answer: ["Done."])
        let contributor = FakeContributor(descriptorsList: [descriptor("a")],
                                          results: ["a": ToolStepResult(tool: "a", status: .done, summary: "ran a")])
        let result = await loop(rt, contributor: contributor).run(context: ctx("do a"))
        XCTAssertEqual(result.outcome, .answered(text: "Done."))
        XCTAssertEqual(result.steps.map(\.summary), ["ran a"], "one tool step ran, then the model answered")
    }

    func testLoopFailedStepEndsFailed() async {
        let rt = RoutingRuntime(routes: ["{\"tool\":\"a\"}"], answer: ["unused"])
        let contributor = FakeContributor(descriptorsList: [descriptor("a")],
                                          results: ["a": ToolStepResult(tool: "a", status: .failed(headline: "Disk full."), summary: "failed a")])
        let result = await loop(rt, contributor: contributor).run(context: ctx("do a"))
        XCTAssertEqual(result.outcome, .failed(headline: "Disk full."), "a side effect that didn't land ends the loop failed")
    }

    func testLoopRepeatedStepGuardStops() async {
        // The same tool+args twice in a row → repeatedStep guard.
        let rt = RoutingRuntime(routes: ["{\"tool\":\"a\",\"argumentsJSON\":\"{}\"}", "{\"tool\":\"a\",\"argumentsJSON\":\"{}\"}"], answer: ["best effort"])
        let contributor = FakeContributor(descriptorsList: [descriptor("a")],
                                          results: ["a": ToolStepResult(tool: "a", status: .done, summary: "ran a")])
        let result = await loop(rt, contributor: contributor).run(context: ctx("do a"))
        guard case let .stopped(reason, text) = result.outcome else { return XCTFail("expected .stopped") }
        XCTAssertEqual(reason, .repeatedStep)
        XCTAssertEqual(text, "best effort", "a guard stop still streams a best-effort final answer")
    }

    func testLoopCapReached() async {
        // Two distinct auto tools, never a plain answer, cap = 2 → capReached.
        let rt = RoutingRuntime(routes: ["{\"tool\":\"a\"}", "{\"tool\":\"b\"}", "{\"tool\":\"a\"}"], answer: ["capped answer"])
        let contributor = FakeContributor(descriptorsList: [descriptor("a"), descriptor("b")])
        let result = await loop(rt, contributor: contributor, maxToolSteps: 2).run(context: ctx("go"))
        XCTAssertEqual(result.outcome, .capReached(text: "capped answer"))
        XCTAssertEqual(result.steps.count, 2, "exactly maxToolSteps tool steps ran before the cap")
    }

    func testLoopThinkingCarriesPlanResponseCarriesAnswerOnly() async {
        let rt = RoutingRuntime(routes: ["{\"tool\":\"a\",\"rationale\":\"because reasons\"}", "{\"tool\":\"\"}"], answer: ["Final."])
        let contributor = FakeContributor(descriptorsList: [descriptor("a")],
                                          results: ["a": ToolStepResult(tool: "a", status: .done, summary: "ran a")])
        let captured = ThinkingSink()
        let result = await loop(rt, contributor: contributor, onThinking: { captured.append($0) }).run(context: ctx("do a"))
        XCTAssertEqual(result.outcome, .answered(text: "Final."), "the committed answer is response-channel only")
        let plan = captured.text
        XCTAssertTrue(plan.contains("because reasons"), "the route rationale rides the thinking channel")
        XCTAssertTrue(plan.contains("ran a"), "the tool-step summary rides the thinking channel")
        XCTAssertFalse(plan.contains("Final."), "the final answer is NOT in the thinking plan")
    }

    func testLoopWidenEnlargesNextTurnsCandidates() async {
        let rt = RoutingRuntime(routes: ["{\"tool\":\"widen_candidates\"}", "{\"tool\":\"\"}"], answer: ["ok"])
        let spy = SpyCandidateSource(inner: KeywordToolCandidateSource(all: [descriptor("a")]))
        let agent = AgentLoop(runtime: rt, registry: ToolRegistry([FakeContributor(descriptorsList: [descriptor("a")])]),
                              candidateSource: spy, gate: ScriptedApprovalGate(), maxToolSteps: 8)
        let result = await agent.run(context: ctx("need more"))
        XCTAssertEqual(result.outcome, .answered(text: "ok"))
        XCTAssertEqual(spy.limits.count, 2, "two route turns")
        XCTAssertGreaterThan(spy.limits[1], spy.limits[0], "a widen step enlarges the next turn's candidate limit")
    }

    func testLoopCancellationViaGateIsQuietNotFailed() async {
        let rt = RoutingRuntime(routes: ["{\"tool\":\"a\"}"], answer: ["unused"])
        let contributor = FakeContributor(descriptorsList: [descriptor("a")]) // default .confirm → consults the gate
        let result = await loop(rt, contributor: contributor, gate: ScriptedApprovalGate([.cancel])).run(context: ctx("do a"))
        // The contributor's FakeContributor ignores the gate; so emulate cancel via the bridge instead:
        _ = result
        let dispatcher = FakeDispatcher()
        let bridge = TaskKindToolContributor(dispatcher: dispatcher, kinds: [.addToCalendar])
        let agent = AgentLoop(runtime: RoutingRuntime(routes: ["{\"tool\":\"add_to_calendar\"}"], answer: ["x"]),
                              registry: ToolRegistry([bridge]),
                              candidateSource: KeywordToolCandidateSource(all: bridge.descriptors()),
                              gate: ScriptedApprovalGate([.cancel]))
        let r = await agent.run(context: ctx("lunch tomorrow"))
        XCTAssertEqual(r.outcome, .stopped(reason: .cancelled, text: ""), "a gate cancel ends the loop quietly")
        XCTAssertEqual(dispatcher.executed, 0, "cancel fires no side effect")
    }

    /// `refactor-park-and-background-agents`: the terminal "task complete" classification was RETIRED —
    /// a settled outcome never marks a session for removal. The outcome cases remain distinct values
    /// (the engine maps them to settlements; the paused case never fabricates text).
    func testAgentLoopOutcomeCasesStayDistinct() {
        XCTAssertNotEqual(AgentLoopOutcome.answered(text: "x"), .capReached(text: "x"))
        XCTAssertNotEqual(AgentLoopOutcome.stopped(reason: .cancelled, text: ""), .pausedAwaitingUser)
        XCTAssertNotEqual(AgentLoopOutcome.pausedAwaitingUser, .failed(headline: "x"))
    }

    // MARK: - Test helpers

    private final class ThinkingSink: @unchecked Sendable {
        private var buf = ""
        private let lock = NSLock()
        func append(_ s: String) { lock.lock(); buf += s; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return buf }
    }

    private final class SpyCandidateSource: ToolCandidateSource, @unchecked Sendable {
        let inner: ToolCandidateSource
        private(set) var limits: [Int] = []
        private let lock = NSLock()
        init(inner: ToolCandidateSource) { self.inner = inner }
        func candidates(for context: RouteContext, limit: Int) -> [ToolDescriptor] {
            lock.lock(); limits.append(limit); lock.unlock()
            return inner.candidates(for: context, limit: limit)
        }
    }
}
