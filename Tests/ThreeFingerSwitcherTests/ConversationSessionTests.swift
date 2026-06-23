import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the executor's evolution from a one-shot fire into a multi-turn SESSION
/// (`ai-conversation-runtime`, tasks §5/§6): a seed opens turn one, a later turn sees the earlier turns,
/// thinking streams live + is stored for display but NEVER re-fed, a per-turn error is observable, and a
/// mid-turn discard leaves no partial message and is not a failure. The one-shot preset path is covered
/// by `AICommandExecutorTests` and is untouched here.
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

    private final class FakeTaskDispatcher: TaskDispatching {
        func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource,
                     reasoning: Bool) async -> TaskReview { .unavailable(reason: "unused") }
        func execute(_ review: TaskReview) async throws {}
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
        let registry = ModelRegistry(
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

    private func makeExecutor(_ manager: ModelManager,
                              budget: ContextBudgetProviding = DefaultContextBudget()) -> AICommandExecutor {
        AICommandExecutor(modelManager: manager, selection: FakeSelectionProvider(),
                          dispatcher: FakeTaskDispatcher(), budgetProvider: budget)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool, timeout: TimeInterval = 2.0,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(predicate(), "condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - Seed opens turn one

    func testStartConversationStreamsFirstTurn() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Hello ", "there"], interTokenDelayNanos: 0)
        let executor = makeExecutor(try await loadedManager(runtime: stub))

        executor.startConversation(seedText: "hi")
        await waitUntil { executor.state == .awaitingTurn }

        let convo = try XCTUnwrap(executor.conversation)
        XCTAssertEqual(convo.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(convo.messages[0].text, "hi", "the seed is turn 1 (a user message)")
        XCTAssertEqual(convo.messages[1].text, "Hello there", "the assistant turn carries the response")
    }

    func testEmptySeedSurfacesNoInputAndOpensNoConversation() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["SHOULD NOT APPEAR"], interTokenDelayNanos: 0)
        let executor = makeExecutor(try await loadedManager(runtime: stub))

        executor.startConversation(seedText: "   ")   // whitespace-only, no image
        await waitUntil { executor.state == .noInput }
        XCTAssertNil(executor.conversation, "an empty seed opens no conversation and never calls the model")
    }

    func testImageSeedOpensTurnOneCarryingTheImage() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["ok"], interTokenDelayNanos: 0)
        let executor = makeExecutor(try await loadedManager(runtime: stub))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0A])

        executor.startConversation(seedText: "", image: png)   // image-only seed is valid
        await waitUntil { executor.state == .awaitingTurn }

        let convo = try XCTUnwrap(executor.conversation)
        XCTAssertEqual(convo.messages.first?.image, png, "the seed's image rides on turn 1")
        XCTAssertEqual(executor.assembleRequest()?.effectiveImage, png, "assembly carries the latest image")
    }

    // MARK: - A later turn sees earlier turns; thinking is never re-fed

    func testSecondTurnSeesFirstTurnAndThinkingNeverReFed() async throws {
        let stub = StubLLMRuntime(
            scriptedTurns: [.init(tokens: ["A1"], thinking: ["SECRET-REASONING"]),
                            .init(tokens: ["A2"])],
            interTokenDelayNanos: 0)
        let executor = makeExecutor(try await loadedManager(runtime: stub))

        executor.startConversation(seedText: "U1", reasoning: true)
        await waitUntil { executor.state == .awaitingTurn }
        XCTAssertEqual(executor.conversation?.messages[1].text, "A1")
        XCTAssertEqual(executor.conversation?.messages[1].thinking, "SECRET-REASONING",
                       "the turn's reasoning is stored on the message for display")
        XCTAssertEqual(executor.thinking, "SECRET-REASONING", "thinking streamed live during the turn")

        // The assembled context for the NEXT turn sees turn 1's text — but never its thinking.
        let request = try XCTUnwrap(executor.assembleRequest())
        let assembled = ChatTemplate.flatten(request.messages)
        XCTAssertTrue(assembled.contains("U1"), "the later turn's context contains the earlier user turn")
        XCTAssertTrue(assembled.contains("A1"), "the later turn's context contains the earlier assistant turn")
        XCTAssertFalse(assembled.contains("SECRET-REASONING"),
                       "no prior turn's thinking appears in the assembled context")

        // Send turn 2.
        executor.continueConversation("U2")
        await waitUntil { executor.conversation?.messages.count == 4 }
        XCTAssertEqual(executor.conversation?.messages.map(\.text), ["U1", "A1", "U2", "A2"])
        XCTAssertEqual(executor.state, .awaitingTurn)
        XCTAssertEqual(executor.thinking, "",
                       "live thinking is reset at each turn start; turn 2 had none, so it shows nothing")
    }

    // MARK: - Per-turn failure is observable, history is not dropped

    func testPerTurnErrorSurfacesFailedWithoutDroppingHistory() async throws {
        let stub = StubLLMRuntime(
            scriptedTurns: [.init(tokens: ["A1"]), .init(error: .serverUnavailable)],
            interTokenDelayNanos: 0)
        let executor = makeExecutor(try await loadedManager(runtime: stub))

        executor.startConversation(seedText: "U1")
        await waitUntil { executor.state == .awaitingTurn }

        executor.continueConversation("U2")
        await waitUntil { if case .failed = executor.state { return true }; return false }

        guard case let .failed(message) = executor.state else { return XCTFail("expected .failed") }
        XCTAssertEqual(message, RuntimeError.serverUnavailable.errorDescription,
                       "the failure carries the clean translated headline, not a raw dump")
        XCTAssertEqual(executor.conversation?.messages.map(\.text), ["U1", "A1", "U2"],
                       "the user turn stays; no partial assistant turn is appended; history is not dropped")
    }

    // MARK: - Mid-turn discard leaves no partial message and is not a failure

    func testDiscardTurnLeavesNoPartialAndIsNotAFailure() async throws {
        let stub = StubLLMRuntime(
            scriptedTurns: [.init(tokens: ["A1"]),
                            .init(tokens: Array(repeating: "x", count: 50))],
            interTokenDelayNanos: 5_000_000)   // 5 ms/token so turn 2 streams long enough to discard
        let executor = makeExecutor(try await loadedManager(runtime: stub))

        executor.startConversation(seedText: "U1")
        await waitUntil { executor.state == .awaitingTurn }

        executor.continueConversation("U2")
        await waitUntil { if case .conversing = executor.state { return true }; return false }
        executor.discardTurn()

        XCTAssertEqual(executor.state, .awaitingTurn, "a discarded turn returns the thread to idle, not failed")
        XCTAssertEqual(executor.conversation?.messages.map(\.text), ["U1", "A1", "U2"],
                       "no partial assistant message is appended for the discarded turn")
        await waitUntil { stub.observedCancellation }
        XCTAssertTrue(stub.observedCancellation, "generation was actually cancelled")
    }

    // MARK: - The one-shot path is preserved (a fire clears any prior conversation)

    func testFireClearsAnyOpenConversation() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["answer"], interTokenDelayNanos: 0)
        let executor = makeExecutor(try await loadedManager(runtime: stub))

        executor.startConversation(seedText: "U1")
        await waitUntil { executor.state == .awaitingTurn }
        XCTAssertNotNil(executor.conversation)

        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .clipboard,
                                promptTemplate: "{input}", output: .previewOnly)
        executor.fire(command)
        XCTAssertNil(executor.conversation, "a one-shot preset fire is not part of a conversation thread")
    }
}
