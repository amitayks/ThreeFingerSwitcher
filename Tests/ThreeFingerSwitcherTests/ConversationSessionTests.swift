import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the notch-session multi-turn engine (`notch-native-conversations` D1 — the executor's
/// conversational half re-homed into `NotchSessionEngine`): a new session's first typed turn streams, a
/// later turn sees the earlier turns, thinking streams live + is stored for display but NEVER re-fed, a
/// per-turn error is observable, and a mid-turn discard leaves no partial message and is not a failure.
/// The one-shot preset path is covered by `AICommandExecutorTests` and is untouched here.
@MainActor
final class ConversationSessionTests: XCTestCase {

    // MARK: - Harness

    private final class FakeSelectionProvider: SelectionProviding {
        func readSelectedText() async -> String? { nil }
        func readClipboardText() -> String? { nil }
        func readClipboardImage() -> Data? { nil }
        @discardableResult func replaceSelection(_ text: String) async -> Bool { true }
        @discardableResult func pasteAtCursor(_ text: String) async -> Bool { true }
    }

    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        let payload: Data
        init(payload: Data) { self.payload = payload }
        func download(_ descriptor: ModelDescriptor, to destination: URL,
                      progress: @Sendable (Double) -> Void) async throws -> Data {
            progress(1.0); return payload
        }
    }

    private func loadedManager(runtime: LLMRuntime,
                               capabilities: Set<Modality> = [.text, .vision]) async throws -> ModelManager {
        let payload = Data("weights".utf8)
        let registry = ModelCatalog(
            models: [ModelDescriptor(id: "test-model", displayName: "Test Model",
                                     sizeBytes: Int64(payload.count),
                                     integritySHA: ModelManager.sha256Hex(payload),
                                     downloadURL: URL(string: "https://models.invalid/test-model")!,
                                     capabilities: capabilities, quantization: .qat4bit)],
            defaultModelID: "test-model")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-conversation-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = ModelManager(registry: registry, downloader: FakeDownloader(payload: payload),
                                   optedIn: true, storageRoot: root, runtimeFactory: { _ in runtime })
        try await manager.downloadAndVerify(registry.models[0])
        return manager
    }

    private func makeEngine(_ manager: ModelManager,
                            reasoning: Bool = false,
                            budget: ContextBudgetProviding = DefaultContextBudget()) -> NotchSessionEngine {
        NotchSessionEngine(modelManager: manager, selection: FakeSelectionProvider(),
                           reasoning: { reasoning }, budgetProvider: budget)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool, timeout: TimeInterval = 2.0,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(predicate(), "condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - The first typed turn opens the thread (and names the session)

    func testFirstSendStreamsFirstTurnAndNamesTheSession() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Hello ", "there"], interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub))

        let born = engine.startNew()
        XCTAssertEqual(born.title, "New chat", "a fresh session carries the placeholder title")
        XCTAssertEqual(engine.state, .awaitingTurn, "a new session idles awaiting its first typed turn")

        engine.send("hi")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        let convo = try XCTUnwrap(engine.conversation)
        XCTAssertEqual(convo.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(convo.messages[0].text, "hi", "the typed message is turn 1 (a user message)")
        XCTAssertEqual(convo.messages[1].text, "Hello there", "the assistant turn carries the response")
        XCTAssertEqual(convo.title, "hi", "the first turn names the session (was the placeholder)")
        XCTAssertEqual(convo.id, born.id, "the session identity is stable from birth")
    }

    func testEmptySendIsANoOp() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["SHOULD NOT APPEAR"], interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub))

        engine.startNew()
        engine.send("   ")   // whitespace-only, no images
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(engine.state, .awaitingTurn, "an empty send never runs the model")
        XCTAssertEqual(engine.conversation?.messages.count, 0, "no message is appended for an empty send")
    }

    func testSendWithImageCarriesItOnTheTurn() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["ok"], interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0A])

        engine.startNew()
        engine.send("what is this?", images: [png])
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        let convo = try XCTUnwrap(engine.conversation)
        XCTAssertEqual(convo.messages.first?.images, [png], "the turn's image rides on the user message")
        XCTAssertEqual(engine.assembleRequest()?.effectiveImage, png, "assembly carries the latest image")
    }

    // MARK: - A later turn sees earlier turns; thinking is never re-fed

    func testSecondTurnSeesFirstTurnAndThinkingNeverReFed() async throws {
        let stub = StubLLMRuntime(
            scriptedTurns: [.init(tokens: ["A1"], thinking: ["SECRET-REASONING"]),
                            .init(tokens: ["A2"])],
            interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub), reasoning: true)

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }
        XCTAssertEqual(engine.conversation?.messages[1].text, "A1")
        XCTAssertEqual(engine.conversation?.messages[1].thinking, "SECRET-REASONING",
                       "the turn's reasoning is stored on the message for display")
        XCTAssertEqual(engine.thinking, "SECRET-REASONING", "thinking streamed live during the turn")

        // The assembled context for the NEXT turn sees turn 1's text — but never its thinking.
        let request = try XCTUnwrap(engine.assembleRequest())
        let assembled = ChatTemplate.flatten(request.messages)
        XCTAssertTrue(assembled.contains("U1"), "the later turn's context contains the earlier user turn")
        XCTAssertTrue(assembled.contains("A1"), "the later turn's context contains the earlier assistant turn")
        XCTAssertFalse(assembled.contains("SECRET-REASONING"),
                       "no prior turn's thinking appears in the assembled context")

        // Send turn 2.
        engine.send("U2")
        await waitUntil { engine.conversation?.messages.count == 4 }
        XCTAssertEqual(engine.conversation?.messages.map(\.text), ["U1", "A1", "U2", "A2"])
        XCTAssertEqual(engine.state, .awaitingTurn)
        XCTAssertEqual(engine.thinking, "",
                       "live thinking is reset at each turn start; turn 2 had none, so it shows nothing")
    }

    // MARK: - Every settled turn reports a durable snapshot (the collapse-mid-turn contract's seam)

    func testTurnSettledReportsSnapshotWithTheAppendedTurn() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["A1"], interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub))
        var settled: [(AgentConversation, NotchSessionEngine.TurnSettlement)] = []
        engine.onTurnSettled = { conversation, settlement in settled.append((conversation, settlement)) }

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        XCTAssertEqual(settled.count, 1, "exactly one settle per completed turn")
        XCTAssertEqual(settled.first?.0.messages.map(\.text), ["U1", "A1"],
                       "the settled snapshot carries the appended assistant turn")
        XCTAssertEqual(settled.first?.1, .answered,
                       "a settled chat turn is an ANSWER — there is no terminal task-completion notion")
    }

    // MARK: - Per-turn failure is observable, history is not dropped

    func testPerTurnErrorSurfacesFailedWithoutDroppingHistory() async throws {
        let stub = StubLLMRuntime(
            scriptedTurns: [.init(tokens: ["A1"]), .init(error: .serverUnavailable)],
            interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub))

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        engine.send("U2")
        await waitUntil { if case .failed = engine.state { return true }; return false }

        guard case let .failed(message) = engine.state else { return XCTFail("expected .failed") }
        XCTAssertEqual(message, RuntimeError.serverUnavailable.errorDescription,
                       "the failure carries the clean translated headline, not a raw dump")
        XCTAssertEqual(engine.conversation?.messages.map(\.text), ["U1", "A1", "U2"],
                       "the user turn stays; no partial assistant turn is appended; history is not dropped")
    }

    // MARK: - Mid-turn discard leaves no partial message and is not a failure

    func testDiscardTurnLeavesNoPartialAndIsNotAFailure() async throws {
        let stub = StubLLMRuntime(
            scriptedTurns: [.init(tokens: ["A1"]),
                            .init(tokens: Array(repeating: "x", count: 50))],
            interTokenDelayNanos: 5_000_000)   // 5 ms/token so turn 2 streams long enough to discard
        let engine = makeEngine(try await loadedManager(runtime: stub))

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        engine.send("U2")
        await waitUntil { if case .conversing = engine.state { return true }; return false }
        engine.discardTurn()

        XCTAssertEqual(engine.state, .awaitingTurn, "a discarded turn returns the thread to idle, not failed")
        XCTAssertEqual(engine.conversation?.messages.map(\.text), ["U1", "A1", "U2"],
                       "no partial assistant message is appended for the discarded turn")
        await waitUntil { stub.observedCancellation }
        XCTAssertTrue(stub.observedCancellation, "generation was actually cancelled")
    }

    // MARK: - Bind / unbind (the expand / collapse verbs' engine half)

    func testBindIdlesAwaitingTurnAndUnbindReturnsTheSnapshot() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["A1"], interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub))

        let now = Date()
        let stored = AgentConversation(
            title: "Stored",
            messages: [AgentMessage(role: .user, text: "old", createdAt: now),
                       AgentMessage(role: .assistant, text: "answer", createdAt: now)],
            createdAt: now, updatedAt: now)
        engine.bind(stored)
        XCTAssertEqual(engine.state, .awaitingTurn, "a bound session idles awaiting the next turn")
        XCTAssertEqual(engine.conversation?.id, stored.id)

        let snapshot = engine.unbind()
        XCTAssertEqual(snapshot?.id, stored.id, "unbind hands the snapshot back for persistence")
        XCTAssertEqual(engine.state, .idle, "an idle unbind fully resets the engine")
        XCTAssertNil(engine.conversation)
    }

    func testUnbindMidTurnKeepsTheTurnRunningToSettlement() async throws {
        let stub = StubLLMRuntime(
            scriptedTokens: Array(repeating: "x", count: 40),
            interTokenDelayNanos: 5_000_000)
        let engine = makeEngine(try await loadedManager(runtime: stub))
        var settled: [(AgentConversation, NotchSessionEngine.TurnSettlement)] = []
        engine.onTurnSettled = { conversation, settlement in settled.append((conversation, settlement)) }

        engine.startNew()
        engine.send("U1")
        await waitUntil { if case .conversing = engine.state { return true }; return false }

        let snapshot = engine.unbind()   // collapse mid-turn: does NOT cancel
        XCTAssertNotNil(snapshot, "collapse still gets a snapshot to persist")
        XCTAssertTrue(engine.isTurnInFlight, "the in-flight turn survives the unbind (collapse ≠ cancel)")

        await waitUntil({ !settled.isEmpty }, timeout: 4.0)
        XCTAssertEqual(settled.first?.0.messages.count, 2,
                       "the detached turn ran to completion and reported its settled snapshot")
        XCTAssertFalse(stub.observedCancellation, "the turn was never cancelled by the collapse")
    }

    // MARK: - Routed turns (registry-wired — the production path the old suite never exercised,
    // which is exactly how the detached-settle deletion bug stayed invisible)

    /// A scripted routing runtime: `structured()` dequeues route JSON; `generate()` streams the answer
    /// (thinking chunks first, in order).
    private final class ScriptedRoutingRuntime: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        private var routes: [String]
        private let answerTokens: [String]
        private let thinkingChunks: [String]
        private let lock = NSLock()
        init(routes: [String], answer: [String], thinking: [String] = []) {
            self.routes = routes; self.answerTokens = answer; self.thinkingChunks = thinking
        }
        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            let thinks = thinkingChunks, toks = answerTokens
            return AsyncThrowingStream { c in
                for t in thinks { c.yield(Token(t, isFinal: false, channel: .thinking)) }
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

    /// A confirm-tier tool whose run awaits the injected gate — the foreground approval path.
    private final class GatedContributor: ToolContributor, @unchecked Sendable {
        let descriptor: ToolDescriptor
        private(set) var ran = false
        init(name: String) {
            descriptor = ToolDescriptor(name: name, summary: "s",
                                        argsSchema: StructuredSchema(name: name, json: "{\"type\":\"object\"}"),
                                        writePolicy: .confirm)
        }
        func descriptors() -> [ToolDescriptor] { [descriptor] }
        func canHandle(_ tool: String) -> Bool { tool == descriptor.name }
        func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
            switch await gate.awaitDecision(for: .unavailable(reason: "approve me")) {
            case .approve:
                ran = true
                return ToolStepResult(tool: descriptor.name, status: .done, summary: "did it")
            case .skip:
                return ToolStepResult(tool: descriptor.name, status: .declined(reason: "skipped"), summary: "skipped")
            case .cancel:
                return ToolStepResult(tool: descriptor.name,
                                      status: .declined(reason: TaskKindToolContributor.cancelledReason),
                                      summary: "cancelled")
            }
        }
    }

    private func makeRoutedEngine(_ manager: ModelManager, registry: ToolRegistry) -> NotchSessionEngine {
        NotchSessionEngine(modelManager: manager, selection: FakeSelectionProvider(),
                           registry: registry,
                           candidateSource: KeywordToolCandidateSource(all: { registry.allDescriptors() }))
    }

    func testRoutedPlainAnswerSettlesAnsweredWithOrderedThinking() async throws {
        let rt = ScriptedRoutingRuntime(routes: ["{\"tool\":\"\"}"], answer: ["A1"],
                                        thinking: ["T1", "T2", "T3"])
        let engine = makeRoutedEngine(try await loadedManager(runtime: rt), registry: ToolRegistry([]))
        var settled: [(AgentConversation, NotchSessionEngine.TurnSettlement)] = []
        engine.onTurnSettled = { settled.append(($0, $1)) }

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        XCTAssertEqual(settled.map(\.1), [.answered],
                       "a routed answer settles as ANSWERED — never a terminal 'task complete'")
        XCTAssertEqual(settled.first?.0.messages.last?.text, "A1")
        XCTAssertEqual(engine.thinking, "T1T2T3",
                       "reasoning tokens land in order — the stream is turn-owned, drained before settle")
    }

    func testDockedApprovalSurvivesAndApproveResumesTheSameStep() async throws {
        let tool = GatedContributor(name: "confirm_tool")
        let rt = ScriptedRoutingRuntime(routes: ["{\"tool\":\"confirm_tool\"}", "{\"tool\":\"\"}"],
                                        answer: ["done"])
        let engine = makeRoutedEngine(try await loadedManager(runtime: rt), registry: ToolRegistry([tool]))
        var settled: [(AgentConversation, NotchSessionEngine.TurnSettlement)] = []
        engine.onTurnSettled = { settled.append(($0, $1)) }

        engine.startNew()
        engine.send("go")
        await waitUntil { engine.isPausedAtApproval }
        XCTAssertTrue(engine.isTurnInFlight,
                      "a paused approval counts as in flight — docking must keep the engine")

        let snapshot = engine.unbind()   // dock while paused at the gate
        XCTAssertNotNil(snapshot, "the dock still gets a snapshot to persist")
        XCTAssertTrue(engine.isTurnInFlight, "the suspended gate survives the dock (no orphaned continuation)")
        XCTAssertNotNil(engine.conversation, "the conversation stays bound while the turn is in flight")

        XCTAssertTrue(engine.approve(), "re-expanding re-presents the SAME pending step; approve resumes it")
        await waitUntil { !settled.isEmpty }
        XCTAssertTrue(tool.ran, "the approved step actually fired — the turn was never restarted")
        XCTAssertEqual(settled.map(\.1), [.answered])
        XCTAssertEqual(settled.first?.0.messages.last?.text, "done")
    }

    // MARK: - advance() (the background driver's verb)

    // MARK: - The timeline (`notch-timeline-and-tuning`): interleaved segments, streamed + persisted

    /// A runtime whose `generate` yields an arbitrary CHANNEL SCRIPT — interleaved thinking/response
    /// chunks in exact order (the stub emits thinking-then-response only, which can't exercise a flip
    /// back). `structured()` dequeues route JSON so the same type drives routed turns.
    private final class ChannelScriptRuntime: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        private var routes: [String]
        private let script: [(TokenChannel, String)]
        private let lock = NSLock()
        init(script: [(TokenChannel, String)], routes: [String] = []) {
            self.script = script; self.routes = routes
        }
        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            let script = self.script
            return AsyncThrowingStream { c in
                for (i, entry) in script.enumerated() {
                    c.yield(Token(entry.1, isFinal: i == script.count - 1, channel: entry.0))
                }
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

    func testTimelineInterleavesChannelsInArrivalOrderAndPersistsOnSettle() async throws {
        let rt = ChannelScriptRuntime(script: [(.thinking, "T1"), (.response, "R1"),
                                               (.thinking, "T2"), (.response, "R2")])
        let engine = makeEngine(try await loadedManager(runtime: rt), reasoning: true)

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        let message = try XCTUnwrap(engine.conversation?.messages.last)
        XCTAssertEqual(message.text, "R1R2", "the committed text is the response channel only")
        XCTAssertEqual(message.thinking, "T1T2", "the flat thinking accumulation is unchanged")
        XCTAssertEqual(message.segments,
                       [TurnSegment(kind: .thinking, text: "T1"),
                        TurnSegment(kind: .answer, text: "R1"),
                        TurnSegment(kind: .thinking, text: "T2"),
                        TurnSegment(kind: .answer, text: "R2")],
                       "the persisted timeline preserves cross-channel ARRIVAL order — a segment per flip")
        XCTAssertTrue(engine.liveSegments.isEmpty,
                      "the live timeline hands off to the persisted message at settle")
    }

    func testTimelineCoalescesSameChannelChunksIntoOneSegment() async throws {
        let rt = ChannelScriptRuntime(script: [(.thinking, "Ta"), (.thinking, "Tb"), (.response, "R")])
        let engine = makeEngine(try await loadedManager(runtime: rt), reasoning: true)

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        XCTAssertEqual(engine.conversation?.messages.last?.segments,
                       [TurnSegment(kind: .thinking, text: "TaTb"),
                        TurnSegment(kind: .answer, text: "R")],
                       "consecutive same-channel chunks coalesce — the array grows only at channel flips")
    }

    func testRoutedAnswerStreamsLiveInterleavedIntoTheTimeline() async throws {
        // Thinking AFTER the answer chunk can only appear mid-timeline if the answer streamed LIVE
        // (the wired `onResponseToken`); an at-settle append would leave [thinking, answer] instead.
        let rt = ChannelScriptRuntime(script: [(.thinking, "Ta"), (.response, "R1"), (.thinking, "Tb")],
                                      routes: ["{\"tool\":\"\"}"])
        let engine = makeRoutedEngine(try await loadedManager(runtime: rt), registry: ToolRegistry([]))

        engine.startNew()
        engine.send("U1")
        await waitUntil { engine.state == .awaitingTurn && engine.conversation?.messages.count == 2 }

        let message = try XCTUnwrap(engine.conversation?.messages.last)
        XCTAssertEqual(message.text, "R1")
        XCTAssertEqual(message.segments,
                       [TurnSegment(kind: .thinking, text: "Ta"),
                        TurnSegment(kind: .answer, text: "R1"),
                        TurnSegment(kind: .thinking, text: "Tb")],
                       "the routed answer streamed live BETWEEN the thinking chunks — not whole at settle")
    }

    // MARK: - Born-with tuning (`notch-timeline-and-tuning` D7)

    private func makeTunedEngine(_ manager: ModelManager,
                                 reasoning: Bool,
                                 tuning: @escaping @MainActor () -> NotchSessionEngine.TuningSnapshot?)
        -> NotchSessionEngine {
        NotchSessionEngine(modelManager: manager, selection: FakeSelectionProvider(),
                           reasoning: { reasoning }, tuningDefault: tuning)
    }

    func testTuningIsStampedAtBirthAndKeptAcrossRebind() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["A1"], interTokenDelayNanos: 0)
        var dial: NotchSessionEngine.TuningSnapshot? = (reasoning: false, contextTokens: 4_096)
        let engine = makeTunedEngine(try await loadedManager(runtime: stub), reasoning: true,
                                     tuning: { dial })

        let born = engine.startNew()
        XCTAssertEqual(born.reasoningOverride, false, "the dial's reasoning is stamped at birth")
        XCTAssertEqual(born.contextTokens, 4_096, "the dial's context budget is stamped at birth")
        XCTAssertEqual(engine.assembleRequest()?.reasoning, false,
                       "the turn runs with the born-with reasoning, not the global default")

        // The dial moves AFTER birth: a stored conversation keeps the tuning it was born under.
        dial = (reasoning: true, contextTokens: 32_768)
        var stored = born
        stored.messages = [AgentMessage(role: .user, text: "U1")]
        engine.bind(stored)
        XCTAssertEqual(engine.assembleRequest()?.reasoning, false,
                       "re-binding keeps the born-with reasoning — a later slider change never retunes it")
    }

    func testPreChangeConversationFallsBackToTheGlobalReasoningDefault() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["A1"], interTokenDelayNanos: 0)
        let engine = makeTunedEngine(try await loadedManager(runtime: stub), reasoning: true,
                                     tuning: { (reasoning: false, contextTokens: 4_096) })

        // A conversation stored BEFORE the dial existed (no born-with fields) keeps the exact legacy
        // behavior: the global reasoning default re-read at bind.
        let legacy = AgentConversation(title: "old",
                                       messages: [AgentMessage(role: .user, text: "U1")])
        engine.bind(legacy)
        XCTAssertEqual(engine.assembleRequest()?.reasoning, true,
                       "nil born-with tuning falls back to the global reasoning default")
    }

    // MARK: - advance() (the background driver's verb)

    func testAdvanceRunsThePendingTurnAndNoOpsWhenNothingPends() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["A1"], interTokenDelayNanos: 0)
        let engine = makeEngine(try await loadedManager(runtime: stub))
        let now = Date()
        let pending = AgentConversation(
            title: "t",
            messages: [AgentMessage(role: .user, text: "U1", createdAt: now)],
            createdAt: now, updatedAt: now)
        var settled: [(AgentConversation, NotchSessionEngine.TurnSettlement)] = []
        engine.onTurnSettled = { settled.append(($0, $1)) }

        engine.bind(pending)
        engine.advance()
        await waitUntil { !settled.isEmpty }
        XCTAssertEqual(settled.first?.0.messages.map(\.text), ["U1", "A1"],
                       "advance ran the pending turn without appending a new user message")

        engine.advance()   // last message is now the assistant's — nothing pends
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(settled.count, 1, "advance with nothing pending runs no turn")
    }
}
