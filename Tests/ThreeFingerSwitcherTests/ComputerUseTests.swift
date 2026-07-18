import XCTest
@testable import ThreeFingerSwitcherCore

/// `add-voice-computer-use-agent`: the pure AX snapshot builder + the constrained-ID epoch store,
/// the loop's wall-clock budgets, and the auto-approving gate — every rule deterministic, no live
/// AX, no real model.
@MainActor
final class ComputerUseTests: XCTestCase {

    // MARK: - AXSnapshotBuilder

    private func sampleTree() -> AXNodeData {
        AXNodeData(role: "AXWindow", children: [
            AXNodeData(role: "AXStaticText", value: "Hello from the terminal"),
            AXNodeData(role: "AXButton", label: "Send", isPressable: true),
            AXNodeData(role: "AXGroup", children: [
                AXNodeData(role: "AXTextField", label: "Message", value: "draft", isSettable: true),
                AXNodeData(role: "AXStaticText", value: "footer note"),
            ]),
        ])
    }

    func testBuilderExtractsTextAndElements() {
        let snapshot = AXSnapshotBuilder.build(pid: 42, appName: "Terminal", title: "zsh",
                                               root: sampleTree(), epoch: 0)
        XCTAssertEqual(snapshot.textBlocks, ["Hello from the terminal", "draft", "footer note"])
        XCTAssertEqual(snapshot.elements.count, 2)
        XCTAssertTrue(snapshot.elements.contains { $0.label == "Send" && $0.isPressable })
        XCTAssertTrue(snapshot.elements.contains { $0.label == "Message" && $0.isSettable })
        XCTAssertFalse(snapshot.truncated)
    }

    func testStableIDsAreStableAcrossRereadsAndPathSensitive() {
        let first = AXSnapshotBuilder.build(pid: 1, appName: "A", title: "t", root: sampleTree(), epoch: 0)
        let second = AXSnapshotBuilder.build(pid: 1, appName: "A", title: "t", root: sampleTree(), epoch: 0)
        XCTAssertEqual(first.elements.map(\.id), second.elements.map(\.id),
                       "an unchanged window re-reads to the same ids")
        // A moved element (different path) gets a DIFFERENT id — the staleness signal.
        var moved = sampleTree()
        moved.children.swapAt(0, 1)
        let third = AXSnapshotBuilder.build(pid: 1, appName: "A", title: "t", root: moved, epoch: 0)
        XCTAssertNotEqual(first.elements.map(\.id), third.elements.map(\.id))
    }

    func testDepthAndCountLimitsReportTruncationHonestly() {
        // A deep chain past maxDepth.
        var deep = AXNodeData(role: "AXStaticText", value: "leaf")
        for _ in 0..<20 { deep = AXNodeData(role: "AXGroup", children: [deep]) }
        let snapshot = AXSnapshotBuilder.build(pid: 1, appName: "A", title: "t", root: deep, epoch: 0,
                                               limits: .init(maxDepth: 5, maxNodes: 100, maxTextBlocks: 10))
        XCTAssertTrue(snapshot.truncated, "a depth cut must be reported, never silent")
    }

    func testContentHashChangesWithContent() {
        let before = AXSnapshotBuilder.build(pid: 1, appName: "A", title: "t", root: sampleTree(), epoch: 0)
        var changedTree = sampleTree()
        changedTree.children[0].value = "Hello CHANGED"
        let after = AXSnapshotBuilder.build(pid: 1, appName: "A", title: "t", root: changedTree, epoch: 0)
        XCTAssertNotEqual(before.contentHash, after.contentHash)
    }

    // MARK: - AXSnapshotStore (the constrained-ID epoch)

    func testStoreResolvesOnlyCurrentEpoch() throws {
        let store = AXSnapshotStore()
        let first = store.register(AXSnapshotBuilder.build(pid: 7, appName: "A", title: "t",
                                                           root: sampleTree(), epoch: 0))
        let sendID = try XCTUnwrap(first.elements.first(where: { $0.label == "Send" })?.id)
        XCTAssertNoThrow(try store.resolve(sendID, pid: 7))

        // A NEW snapshot with a changed layout replaces the epoch: the old id is now stale.
        var moved = sampleTree()
        moved.children.swapAt(0, 1)
        _ = store.register(AXSnapshotBuilder.build(pid: 7, appName: "A", title: "t",
                                                   root: moved, epoch: 0))
        XCTAssertThrowsError(try store.resolve(sendID, pid: 7)) { error in
            XCTAssertEqual(error as? AXActionError, .staleElement)
        }
        // An unknown pid is stale too (never a guess).
        XCTAssertThrowsError(try store.resolve(sendID, pid: 999))
    }

    // MARK: - LoopBudget in AgentLoop

    /// A contributor whose single tool sleeps forever (cancellation-safe) — the step-timeout victim.
    private struct HangingContributor: ToolContributor {
        func descriptors() -> [ToolDescriptor] {
            [ToolDescriptor(name: "hang_forever", summary: "hangs",
                            argsSchema: StructuredSchema(name: "hang", json: "{\"type\":\"object\"}"),
                            writePolicy: .auto, keywords: ["hang"])]
        }
        func canHandle(_ tool: String) -> Bool { tool == "hang_forever" }
        func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return ToolStepResult(tool: call.descriptor.name, status: .done, summary: "woke up")
        }
    }

    private struct ScriptedGate: ApprovalGate {
        func awaitDecision(for review: TaskReview) async -> ApprovalDecision { .approve }
    }

    func testHungToolStepTimesOutAsCleanBudgetFailure() async {
        // Route script: the model picks the hanging tool once.
        let stub = StubLLMRuntime(capabilities: [.text])
        stub.structuredScript = .valid(json: #"{"tool":"hang_forever","argumentsJSON":"{}"}"#)
        stub.scriptedTokens = ["fallback answer"]
        let registry = ToolRegistry([HangingContributor()])
        let loop = AgentLoop(runtime: stub, registry: registry,
                             candidateSource: KeywordToolCandidateSource(all: { registry.allDescriptors() }),
                             gate: ScriptedGate(),
                             budget: LoopBudget(stepTimeout: 0.15, turnDeadline: 60))
        let result = await loop.run(context: RouteContext(messages: [
            AgentMessage(role: .user, text: "hang please")]))
        // The timed-out step is the terminal failure — a clean budget headline.
        guard case let .failed(headline) = result.outcome else {
            return XCTFail("expected .failed, got \(result.outcome)")
        }
        XCTAssertTrue(headline.contains("timed out"), "budget failure, not a network headline: \(headline)")
        XCTAssertEqual(result.steps.count, 1)
    }

    func testTurnDeadlineTerminatesViaCapFallback() async {
        let stub = StubLLMRuntime(capabilities: [.text])
        stub.scriptedTokens = ["partial summary"]
        let registry = ToolRegistry([HangingContributor()])
        // A stepping clock: the FIRST read (the loop's deadline baseline) is t0; every later read is
        // 11s past it — so the deadline (10s) trips at the first between-steps check.
        let ticks = LockedCounter()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let loop = AgentLoop(runtime: stub, registry: registry,
                             candidateSource: KeywordToolCandidateSource(all: { registry.allDescriptors() }),
                             gate: ScriptedGate(),
                             budget: LoopBudget(stepTimeout: 30, turnDeadline: 10),
                             clock: { ticks.next() == 0 ? t0 : t0.addingTimeInterval(11) })
        let result = await loop.run(context: RouteContext(messages: [
            AgentMessage(role: .user, text: "anything")]))
        guard case .capReached = result.outcome else {
            return XCTFail("expected .capReached via the deadline, got \(result.outcome)")
        }
    }

    // MARK: - AutoApprovingGate

    private final class CountingGate: ApprovalGate, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var decisions: Int { lock.lock(); defer { lock.unlock() }; return count }
        func awaitDecision(for review: TaskReview) async -> ApprovalDecision {
            lock.lock(); count += 1; lock.unlock()
            return .skip
        }
    }

    func testAutoGateApprovesInstantlyAndNarratesUnderGrant() async {
        let base = CountingGate()
        let narrated = LockedStrings()
        let grant = LockedBool(true)
        let gate = AutoApprovingGate(base: base,
                                     isGranted: { grant.value },
                                     narrate: { narrated.append($0) })
        let review = TaskReview.action(title: "Type in Chrome",
                                       fields: [ReviewField("Text", "hello")],
                                       payload: .openTool(tool: "t", action: ParsedOpenTool(applicable: true, reason: nil, payload: "")))
        let decision = await gate.awaitDecision(for: review)
        XCTAssertEqual(decision, .approve)
        XCTAssertEqual(base.decisions, 0, "the base gate is never consulted under the grant")
        XCTAssertEqual(narrated.values.count, 1, "auto-approved acts are narrated — never silent")
        XCTAssertTrue(narrated.values[0].contains("Type in Chrome"))

        // Revoked → transparent pass-through.
        grant.value = false
        let second = await gate.awaitDecision(for: review)
        XCTAssertEqual(second, .skip)
        XCTAssertEqual(base.decisions, 1)
    }

    // MARK: - Contributor flag gating

    func testComputerUseToolsAbsentWhenDisabled() async {
        let arbiter = AgentActionArbiter()
        let contributor = ComputerUseToolContributor(
            enabled: { false },
            resolveWindow: { _, _ in nil },
            focusWindow: { _ in false },
            performer: AXActionPerformer(eventSource: nil),
            arbiter: arbiter,
            narrate: { _ in })
        XCTAssertTrue(contributor.descriptors().isEmpty, "off means ABSENT from candidates")
    }

    func testComputerUseSchemasHaveNoCoordinates() {
        let arbiter = AgentActionArbiter()
        let contributor = ComputerUseToolContributor(
            enabled: { true },
            resolveWindow: { _, _ in nil },
            focusWindow: { _ in false },
            performer: AXActionPerformer(eventSource: nil),
            arbiter: arbiter,
            narrate: { _ in })
        for descriptor in contributor.descriptors() {
            let json = descriptor.argsSchema.json.lowercased()
            XCTAssertFalse(json.contains("\"x\"") || json.contains("\"y\"") || json.contains("coordinate"),
                           "\(descriptor.name) must expose no coordinate surface")
        }
    }

    // MARK: - Arbiter

    func testArbiterAbortFiresOnceWhileActingOnly() async {
        let arbiter = AgentActionArbiter()
        var aborts = 0
        arbiter.onAbort = { aborts += 1 }
        arbiter.humanTouchDetected()
        XCTAssertEqual(aborts, 0, "touch outside an acting scope is a normal gesture")
        _ = await arbiter.acting {
            arbiter.humanTouchDetected()
            arbiter.humanTouchDetected()   // debounced within one act
            return true
        }
        XCTAssertEqual(aborts, 1)
        XCTAssertFalse(arbiter.isActing)
    }
}

/// Lock-guarded fixtures for @Sendable capture in tests.
private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = -1
    /// Returns 0 on the first call, 1, 2, … after.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
