import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the background-autonomy run path (`ai-background-autonomy` 6.1–6.4): the `BackgroundToolRunner`
/// resolves the whitelist-aware effective tier, decides auto/foreground/waitParked/escalate by park state
/// (`BackgroundGate`), runs/escalates/waits, and records an `AuditRecord` for EVERY step — plus the
/// `AgentLoop` routing each tool step through it when injected.
final class BackgroundToolRunnerTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeContributor: ToolContributor, @unchecked Sendable {
        let list: [ToolDescriptor]
        let result: ToolStepResult
        private(set) var runCalled = false
        init(_ list: [ToolDescriptor], result: ToolStepResult) { self.list = list; self.result = result }
        func descriptors() -> [ToolDescriptor] { list }
        func canHandle(_ tool: String) -> Bool { list.contains { $0.name == tool } }
        func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult { runCalled = true; return result }
    }
    private final class SpyScheduler: ParkScheduler, @unchecked Sendable {
        private(set) var escalated: [(AgentSessionID, String)] = []
        func runnableSessions(now: Date, maxSlots: Int) -> [AgentSessionID] { [] }
        func didAdvance(_ id: AgentSessionID, result: ToolStepResult, taskComplete: Bool) {}
        func escalate(_ id: AgentSessionID, reason: String) { escalated.append((id, reason)) }
    }

    private func desc(_ name: String, _ policy: WritePolicyTier) -> ToolDescriptor {
        ToolDescriptor(name: name, summary: "s",
                       argsSchema: StructuredSchema(name: name, json: "{\"type\":\"object\"}"), writePolicy: policy)
    }
    private func call(_ d: ToolDescriptor) -> RoutedCall {
        RoutedCall(descriptor: d, route: ToolRoute(tool: d.name, argumentsJSON: "{}"), userText: "u", source: TaskSource())
    }
    private func runner(parkState: ParkState, audit: AuditLog, scheduler: SpyScheduler? = nil) -> BackgroundToolRunner {
        BackgroundToolRunner(resolver: BackgroundPolicyResolver(), audit: audit, scheduler: scheduler,
                             parkStateOf: { _ in parkState })
    }

    // MARK: - Decision table + audit

    func testContainedAutoRunsInBackgroundAndAudits() async {
        let audit = InMemoryAuditLog()
        let d = desc("memory.write", .auto)   // contained name → effective .auto
        let c = FakeContributor([d], result: ToolStepResult(tool: d.name, status: .done, summary: "saved"))
        let r = await runner(parkState: .parked, audit: audit)
            .run(call(d), sessionID: AgentSessionID(), registry: ToolRegistry([c]), gate: AutoApproveGate())
        XCTAssertEqual(r.status, .done)
        XCTAssertTrue(c.runCalled, "an auto step runs even while parked")
        let rec = audit.recent(limit: 5)
        XCTAssertEqual(rec.count, 1)
        XCTAssertEqual(rec.first?.policy, .auto)
        XCTAssertEqual(rec.first?.wasBackground, true, "applied while parked → background")
    }

    func testParkedConfirmWaitsWithoutRunning() async {
        let audit = InMemoryAuditLog()
        let d = desc("send_to", .confirm)     // external + confirm
        let c = FakeContributor([d], result: ToolStepResult(tool: d.name, status: .done, summary: "sent"))
        let r = await runner(parkState: .parked, audit: audit)
            .run(call(d), sessionID: AgentSessionID(), registry: ToolRegistry([c]), gate: AutoApproveGate())
        XCTAssertEqual(r.status, .awaitingApproval)
        XCTAssertFalse(c.runCalled, "a parked .confirm step waits — it does NOT fire the side effect")
        XCTAssertEqual(audit.recent(limit: 5).first?.policy, .confirm)
    }

    func testParkedDangerousEscalatesAndAudits() async {
        let audit = InMemoryAuditLog()
        let spy = SpyScheduler()
        let d = desc("launch_claude", .dangerous)
        let c = FakeContributor([d], result: ToolStepResult(tool: d.name, status: .done, summary: "x"))
        let id = AgentSessionID()
        let r = await runner(parkState: .parked, audit: audit, scheduler: spy)
            .run(call(d), sessionID: id, registry: ToolRegistry([c]), gate: AutoApproveGate())
        XCTAssertEqual(r.status, .awaitingApproval)
        XCTAssertFalse(c.runCalled, "a parked .dangerous step never fires without foreground approval")
        XCTAssertEqual(spy.escalated.count, 1, "it escalates to the foreground via the scheduler")
        XCTAssertEqual(spy.escalated.first?.0, id)
        XCTAssertEqual(audit.recent(limit: 5).first?.policy, .dangerous)
    }

    func testForegroundConfirmRunsThroughTheGateAndAuditsForeground() async {
        let audit = InMemoryAuditLog()
        let d = desc("send_to", .confirm)
        let c = FakeContributor([d], result: ToolStepResult(tool: d.name, status: .done, summary: "sent"))
        let r = await runner(parkState: .active, audit: audit)
            .run(call(d), sessionID: AgentSessionID(), registry: ToolRegistry([c]), gate: AutoApproveGate())
        XCTAssertEqual(r.status, .done)
        XCTAssertTrue(c.runCalled, "a foreground confirm runs through the canvas approval gate")
        XCTAssertEqual(audit.recent(limit: 5).first?.wasBackground, false)
    }

    // MARK: - AgentLoop routes each step through the runner

    func testAgentLoopRoutesToolStepsThroughTheBackgroundRunner() async {
        let audit = InMemoryAuditLog()
        let d = desc("memory.write", .auto)
        let contributor = FakeContributor([d], result: ToolStepResult(tool: d.name, status: .done, summary: "ran"))
        let bg = BackgroundToolRunner(resolver: BackgroundPolicyResolver(), audit: audit,
                                      parkStateOf: { _ in .parked })
        let rt = RoutingRuntime(routes: ["{\"tool\":\"memory.write\"}", "{\"tool\":\"\"}"], answer: ["done"])
        let loop = AgentLoop(runtime: rt, registry: ToolRegistry([contributor]),
                             candidateSource: KeywordToolCandidateSource(all: [d]),
                             gate: AutoApproveGate(), backgroundRunner: bg)
        let result = await loop.run(context: RouteContext(messages: [AgentMessage(role: .user, text: "save it")]))
        XCTAssertEqual(result.outcome, .answered(text: "done"))
        XCTAssertEqual(audit.recent(limit: 5).count, 1, "the loop's tool step was routed through the runner + audited")
    }

    /// A minimal routing runtime: structured() dequeues scripted route JSON; generate() streams an answer.
    private final class RoutingRuntime: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        private var routes: [String]; private let answerTokens: [String]; private let lock = NSLock()
        init(routes: [String], answer: [String]) { self.routes = routes; self.answerTokens = answer }
        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            let toks = answerTokens
            return AsyncThrowingStream { c in for (i, t) in toks.enumerated() { c.yield(Token(t, isFinal: i == toks.count - 1)) }; c.finish() }
        }
        func structured<T: Decodable & Sendable>(_ r: LLMRequest, schema: StructuredSchema, as type: T.Type) async throws -> StructuredOutcome<T> {
            let json: String = { lock.lock(); defer { lock.unlock() }; return routes.isEmpty ? "{\"tool\":\"\"}" : routes.removeFirst() }()
            return .value(try JSONDecoder().decode(T.self, from: Data(json.utf8)))
        }
    }
}
