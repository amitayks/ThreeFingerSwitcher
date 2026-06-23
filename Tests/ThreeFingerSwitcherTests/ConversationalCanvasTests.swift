import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the conversational-canvas slice's pure executor machine (`ai-conversational-canvas`): the
/// additive `.awaitingSeed`/`.parked` states, opening the canvas on a waiting seed, sending turn 1
/// (typed question folded with the seed, or the bare-seed default), follow-up turns, extracting the
/// latest answer, and parking the conversation. The SwiftUI canvas + live gestures are user-run-verify.
@MainActor
final class ConversationalCanvasTests: XCTestCase {

    // MARK: - Harness

    private final class FakeSelection: SelectionProviding {
        var replaceLands = true
        /// Scriptable live-clipboard image bytes (design D2): `attachClipboardImage()` reads via this seam.
        var clipboardImage: Data?
        private(set) var replaced: [String] = []
        func readSelectedText() async -> String? { nil }
        func readClipboardText() -> String? { nil }
        func readClipboardImage() -> Data? { clipboardImage }
        @discardableResult func replaceSelection(_ text: String) async -> Bool { replaced.append(text); return replaceLands }
        @discardableResult func pasteAtCursor(_ text: String) async -> Bool { true }
    }
    private final class FakeDispatcher: TaskDispatching {
        func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource, reasoning: Bool) async -> TaskReview { .unavailable(reason: "unused") }
        func execute(_ review: TaskReview) async throws {}
    }
    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        let payload: Data; init(payload: Data) { self.payload = payload }
        func download(_ d: ModelDescriptor, to dest: URL, progress: @Sendable (Double) -> Void) async throws -> Data { progress(1); return payload }
    }
    private func loadedManager(_ runtime: LLMRuntime) async throws -> ModelManager {
        let payload = Data("w".utf8)
        let registry = ModelRegistry(models: [ModelDescriptor(id: "m", displayName: "M", sizeBytes: 1,
            integritySHA: ModelManager.sha256Hex(payload), downloadURL: URL(string: "https://x.invalid/m")!,
            capabilities: [.text, .vision], quantization: .qat4bit)], defaultModelID: "m")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tfs-canvas-\(UUID().uuidString)")
        let m = ModelManager(registry: registry, downloader: FakeDownloader(payload: payload), optedIn: true,
                             storageRoot: root, runtimeFactory: { _ in runtime })
        try await m.downloadAndVerify(registry.models[0]); return m
    }
    private func makeExecutor(_ m: ModelManager) -> AICommandExecutor {
        AICommandExecutor(modelManager: m, selection: FakeSelection(), dispatcher: FakeDispatcher())
    }
    private func makeExecutor(_ m: ModelManager, selection: FakeSelection) -> AICommandExecutor {
        AICommandExecutor(modelManager: m, selection: selection, dispatcher: FakeDispatcher())
    }
    private func waitUntil(_ p: @MainActor () -> Bool, _ timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !p() && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(p(), "condition not met", file: file, line: line)
    }

    // MARK: - New state cases

    func testNewStatesAreNotCommittable() {
        XCTAssertFalse(AICommandExecutor.State.awaitingSeed.isCommittable)
        XCTAssertFalse(AICommandExecutor.State.parked.isCommittable)
        XCTAssertFalse(AICommandExecutor.State.awaitingTurn.isCommittable)
        XCTAssertFalse(AICommandExecutor.State.conversing(partial: "x").isCommittable)
        XCTAssertEqual(AICommandExecutor.State.awaitingSeed, .awaitingSeed)
        XCTAssertEqual(AICommandExecutor.State.parked, .parked)
        XCTAssertNotEqual(AICommandExecutor.State.awaitingSeed, .parked)
    }

    // MARK: - Opening the canvas on a waiting seed

    func testOpenConversationalCanvasWaitsOnSeed() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["SHOULD NOT RUN YET"], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        e.openConversationCanvas(seedText: "some copied text", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        XCTAssertEqual(e.state, .awaitingSeed, "a conversational open waits on the seed — the model is NOT run")
        XCTAssertEqual(e.conversation?.messages.map(\.role), [.user], "turn 1 (the seed) is shown but not yet sent")
        XCTAssertEqual(e.conversation?.messages.first?.text, "some copied text")
    }

    func testEmptySeedOpensNoConversation() async throws {
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
        e.openConversationCanvas(seedText: "   ", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        XCTAssertEqual(e.state, .noInput)
        XCTAssertNil(e.conversation)
    }

    func testPresetAutoSendsTurnOne() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Fixed."], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        // A preset is a pre-filled, auto-sent turn 1 (design D5).
        e.openConversationCanvas(seedText: "teh txt", seedKind: .text, output: .replaceSelection,
                                 turn1Prompt: "Fix grammar:\n\nteh txt", autoSendTurn1: true)
        await waitUntil { e.state == .awaitingTurn }
        XCTAssertEqual(e.conversation?.messages.last?.text, "Fixed.", "turn 1 auto-streamed an assistant answer")
    }

    // MARK: - Sending turn 1 from the seed

    func testSendTypedQuestionFoldsWithSeedAndRunsTurnOne() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["An answer."], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        e.openConversationCanvas(seedText: "the document body", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        e.send("What is this about?")
        await waitUntil { e.state == .awaitingTurn }
        let turn1 = try XCTUnwrap(e.conversation?.messages.first)
        XCTAssertTrue(turn1.text.contains("What is this about?") && turn1.text.contains("the document body"),
                      "turn 1 folds the typed question with the shown seed")
        XCTAssertEqual(e.conversation?.messages.last?.text, "An answer.")
    }

    func testBareSeedSendUsesTheDefaultQuestion() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Describing…"], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        // An image seed with no typed question — a bare Enter sends the bare-seed default.
        e.openConversationCanvas(seedText: "", image: Data([0x89, 0x50]), seedKind: .image, output: .previewOnly, autoSendTurn1: false)
        XCTAssertEqual(e.state, .awaitingSeed)
        e.send("")   // bare composer
        await waitUntil { e.state == .awaitingTurn }
        let turn1 = try XCTUnwrap(e.conversation?.messages.first)
        XCTAssertEqual(turn1.text, BareSeedDefault.question(for: .image),
                       "an empty composer on a bare seed sends the seed-kind default question")
    }

    func testFollowUpTurnContinuesTheThread() async throws {
        let stub = StubLLMRuntime(scriptedTurns: [.init(tokens: ["A1"]), .init(tokens: ["A2"])], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        e.openConversationCanvas(seedText: "hello", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        e.send("first question")
        await waitUntil { e.state == .awaitingTurn }
        e.send("a follow-up")
        await waitUntil { e.conversation?.messages.count == 4 }
        XCTAssertEqual(e.conversation?.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(e.conversation?.messages.last?.text, "A2")
    }

    // MARK: - Extract the latest answer (conversational commit)

    func testExtractLatestWritesTheLatestAnswer() async throws {
        let selection = FakeSelection()
        let stub = StubLLMRuntime(scriptedTokens: ["the answer text"], interTokenDelayNanos: 0)
        let e = AICommandExecutor(modelManager: try await loadedManager(stub), selection: selection, dispatcher: FakeDispatcher())
        e.openConversationCanvas(seedText: "x", seedKind: .text, output: .replaceSelection, autoSendTurn1: false)
        e.send("go")
        await waitUntil { e.state == .awaitingTurn }
        await e.extractLatest()
        XCTAssertEqual(e.state, .committed)
        XCTAssertEqual(selection.replaced, ["the answer text"], "extract routes the latest assistant turn to the output target")
    }

    // MARK: - Park hands the conversation off and recedes

    func testParkHandoffFiresOnParkAndTransitionsParked() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["A"], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        var parked: AgentConversation?
        e.onPark = { parked = $0 }
        e.openConversationCanvas(seedText: "thread to park", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        e.parkHandoff()
        XCTAssertEqual(e.state, .parked)
        XCTAssertEqual(parked?.messages.first?.text, "thread to park", "the live conversation is handed to the parked store")
    }

    // MARK: - Restore a parked session (task 6.2)

    func testRestoreConversationRebindsTheThreadAwaitingTurn() async throws {
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
        let restored = AgentConversation(title: "Earlier chat", messages: [
            AgentMessage(role: .user, text: "q"), AgentMessage(role: .assistant, text: "a")
        ])
        e.restoreConversation(restored)
        XCTAssertEqual(e.state, .awaitingTurn)
        XCTAssertEqual(e.conversation?.messages.count, 2)
        XCTAssertEqual(e.conversation?.title, "Earlier chat")
    }

    /// Bug 4 (Core part): the regression — a restored thread was dead to input — is invisible if the only
    /// test asserts the state transition. This proves a restored conversation actually RESPONDS to a
    /// follow-up `send` from `.awaitingTurn` (continueConversation → runTurn streams the assistant turn).
    func testRestoredThreadRespondsToFollowUpTurn() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["A new answer."], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        let restored = AgentConversation(title: "Earlier chat", messages: [
            AgentMessage(role: .user, text: "q"), AgentMessage(role: .assistant, text: "a")
        ])
        e.restoreConversation(restored)
        XCTAssertEqual(e.state, .awaitingTurn)
        XCTAssertEqual(e.conversation?.messages.count, 2)

        e.send("a new question")
        await waitUntil { e.state == .awaitingTurn && e.conversation?.messages.count == 4 }
        XCTAssertEqual(e.conversation?.messages.count, 4, "the follow-up appended a user + an assistant turn")
        XCTAssertEqual(e.conversation?.messages.last?.role, .assistant, "the restored thread streamed a reply")
        XCTAssertEqual(e.conversation?.messages.last?.text, "A new answer.")
        XCTAssertEqual(e.conversation?.messages[2].text, "a new question",
                       "the typed follow-up is appended as the user turn")
    }

    /// Bug 4 tie + design D2: a restored thread accepts a 2nd-turn IMAGE; it rides the appended user
    /// message and `assembleRequest` forwards it to the runtime request.
    func testRestoredThreadFollowUpCarriesImages() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["ok"], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        e.restoreConversation(AgentConversation(title: "Earlier", messages: [
            AgentMessage(role: .user, text: "q"), AgentMessage(role: .assistant, text: "a")
        ]))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        e.send("follow up", images: [png])
        await waitUntil { e.conversation?.messages.count == 4 }
        XCTAssertEqual(e.conversation?.messages[2].images, [png], "the follow-up user turn carries the image")
        // While the assistant turn is appended, the latest image-bearing turn is still turn 3's user msg.
        let req = try XCTUnwrap(e.assembleRequest())
        XCTAssertEqual(req.images, [png], "assembly forwards the latest turn's images to the request")
    }

    // MARK: - Multi-image send + assembly reaches LLMChatRequest (design D2)

    func testSendWithImagesAppendsThemAndAssemblyForwardsThem() async throws {
        let stub = StubLLMRuntime(scriptedTurns: [.init(tokens: ["A1"]), .init(tokens: ["A2"])], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub))
        e.openConversationCanvas(seedText: "hello", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        e.send("first")
        await waitUntil { e.state == .awaitingTurn }

        let png1 = Data([0x01, 0x02]); let png2 = Data([0x03, 0x04])
        e.send("more", images: [png1, png2])
        await waitUntil { e.conversation?.messages.count == 4 }
        let userTurn2 = try XCTUnwrap(e.conversation?.messages[2])
        XCTAssertEqual(userTurn2.images, [png1, png2], "BOTH images ride the appended user turn (multi-image)")
        XCTAssertEqual(userTurn2.text, "more")
        let req = try XCTUnwrap(e.assembleRequest())
        XCTAssertEqual(req.images, [png1, png2], "assembleRequest forwards the FULL images array to LLMChatRequest")
    }

    /// Vision flip (design D2): after attaching images to turn 2, the turn requests [.text, .vision]. We
    /// observe it via a text-only stub: a vision turn against a text-only runtime fails with
    /// `unsupportedModality(.vision)` (the manager selection asked for a vision-capable runtime).
    func testAttachingImagesFlipsTheTurnToVision() async throws {
        // A text+vision stub answers turn 1 (text); a text-only model would be selected for a text turn,
        // but turn 2 carries an image → vision is required. Use a text-ONLY runtime to prove the flip:
        let textOnly = StubLLMRuntime(capabilities: [.text], scriptedTurns: [.init(tokens: ["A1"])],
                                      interTokenDelayNanos: 0)
        let payload = Data("w".utf8)
        let registry = ModelRegistry(models: [ModelDescriptor(id: "m", displayName: "M", sizeBytes: 1,
            integritySHA: ModelManager.sha256Hex(payload), downloadURL: URL(string: "https://x.invalid/m")!,
            capabilities: [.text], quantization: .qat4bit)], defaultModelID: "m")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tfs-vflip-\(UUID().uuidString)")
        let m = ModelManager(registry: registry, downloader: FakeDownloader(payload: payload), optedIn: true,
                             storageRoot: root, runtimeFactory: { _ in textOnly })
        try await m.downloadAndVerify(registry.models[0])
        let e = AICommandExecutor(modelManager: m, selection: FakeSelection(), dispatcher: FakeDispatcher())

        e.openConversationCanvas(seedText: "hello", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        e.send("text turn")          // turn 1: text only → succeeds against the text model
        await waitUntil { e.state == .awaitingTurn }

        e.send("look", images: [Data([0x89, 0x50])])   // turn 2: an image → needsVision → asks [.text,.vision]
        await waitUntil { if case .failed = e.state { return true }; return false }
        guard case let .failed(message) = e.state else { return XCTFail("expected .failed (no vision model)") }
        // The turn DID flip to requiring vision — the manager could find no [.text, .vision] model among the
        // text-only registry, so it fails with a clean capability message (proving `needsVision` flipped).
        XCTAssertTrue(message.lowercased().contains("vision"),
                      "an image turn requires a vision-capable runtime; the text-only model can't serve it: \(message)")
    }

    // MARK: - Composer attachment model purity (design D2 / Bug 6)

    func testClipboardImageAttachmentPopulatesAndClears() async throws {
        let selection = FakeSelection()
        let png = Data([0xAA, 0xBB])
        selection.clipboardImage = png
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)), selection: selection)

        XCTAssertTrue(e.pendingAttachments.isEmpty, "starts empty")
        XCTAssertTrue(e.attachClipboardImage(), "a clipboard image is staged")
        XCTAssertEqual(e.pendingAttachments.images, [png])

        // Staging a screenshot appends; removing by index empties.
        e.attachScreenshot(Data([0xCC]))
        XCTAssertEqual(e.pendingAttachments.images, [png, Data([0xCC])])
        e.removeAttachment(at: 0)
        XCTAssertEqual(e.pendingAttachments.images, [Data([0xCC])])
        e.removeAttachment(at: 5)   // out of range is a no-op
        XCTAssertEqual(e.pendingAttachments.images, [Data([0xCC])])
        e.clearPendingAttachments()
        XCTAssertTrue(e.pendingAttachments.isEmpty, "clear empties")
    }

    func testAttachClipboardImageNoOpWhenClipboardHasNoImage() async throws {
        let selection = FakeSelection()   // clipboardImage == nil
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)), selection: selection)
        XCTAssertFalse(e.attachClipboardImage(), "no image on the clipboard → no staging, not a failure")
        XCTAssertTrue(e.pendingAttachments.isEmpty)
    }

    func testSendFoldsStagedAttachmentsThenClears() async throws {
        let selection = FakeSelection()
        let png = Data([0x11, 0x22])
        selection.clipboardImage = png
        let stub = StubLLMRuntime(scriptedTokens: ["A"], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub), selection: selection)
        e.openConversationCanvas(seedText: "seed text", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        XCTAssertTrue(e.attachClipboardImage())
        XCTAssertEqual(e.pendingAttachments.images, [png])

        e.send("a question")   // bare-seed turn 1: the staged image augments the seed message
        await waitUntil { e.state == .awaitingTurn }
        XCTAssertEqual(e.conversation?.messages.first?.images, [png],
                       "the staged image augments turn 1's seed message (design D2)")
        XCTAssertTrue(e.pendingAttachments.isEmpty, "staged attachments are cleared once folded onto the turn")
    }

    func testParkAndRestoreClearStagedAttachments() async throws {
        let selection = FakeSelection()
        selection.clipboardImage = Data([0x99])
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)), selection: selection)
        e.openConversationCanvas(seedText: "x", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        XCTAssertTrue(e.attachClipboardImage())
        e.parkHandoff()
        XCTAssertTrue(e.pendingAttachments.isEmpty, "parking clears staged-but-unsent attachments")

        // Restore also clears.
        XCTAssertTrue(e.attachClipboardImage())
        e.restoreConversation(AgentConversation(title: "t", messages: [AgentMessage(role: .user, text: "q")]))
        XCTAssertTrue(e.pendingAttachments.isEmpty, "restore starts with an empty composer")
    }

    /// The multi-source composer's exact send path (Bug 6 / design D2): on an idle `.awaitingTurn` thread,
    /// staging a clipboard image AND a screenshot then sending text + the staged images (the composer's
    /// `executor.send(text, images: pendingAttachments.images)`) folds BOTH images onto the appended
    /// follow-up turn, forwards them to the assembled request, and clears the composer.
    func testComposerSendFoldsMultipleStagedSourcesOntoFollowUpThenClears() async throws {
        let selection = FakeSelection()
        let clip = Data([0x01, 0x02])
        let shot = Data([0x03, 0x04])
        selection.clipboardImage = clip
        let stub = StubLLMRuntime(scriptedTokens: ["A1"], interTokenDelayNanos: 0)
        let e = makeExecutor(try await loadedManager(stub), selection: selection)
        // Open + run turn 1 so we land on an idle `.awaitingTurn` thread (the follow-up surface).
        e.openConversationCanvas(seedText: "seed", seedKind: .text, output: .previewOnly, autoSendTurn1: false)
        e.send("turn one")
        await waitUntil { e.state == .awaitingTurn }

        // Stage both sources on the composer, then send EXACTLY as `sendComposer` does.
        XCTAssertTrue(e.attachClipboardImage())
        e.attachScreenshot(shot)
        XCTAssertEqual(e.pendingAttachments.images, [clip, shot], "both sources staged for one turn")
        e.send("look at these", images: e.pendingAttachments.images)
        await waitUntil { e.state == .awaitingTurn }

        let followUp = try XCTUnwrap(e.conversation?.messages.last(where: { $0.role == .user }))
        XCTAssertEqual(followUp.text, "look at these")
        XCTAssertEqual(followUp.images, [clip, shot], "BOTH staged images ride the one follow-up turn (multi-image)")
        let req = try XCTUnwrap(e.assembleRequest())
        XCTAssertEqual(req.images, [clip, shot], "assembly forwards the full staged-image set to the request")
        XCTAssertTrue(e.pendingAttachments.isEmpty, "the composer clears once the turn folds the images")
    }

    // MARK: - The FIRE-path preset-vs-Ask classification (task 6.1)

    func testConversationalAskVsPresetClassification() {
        // A generic Ask: empty/`{input}`-only template + previewOnly → open-and-wait (no auto-send).
        let ask = AICommand(name: "Ask", icon: .sfSymbol("text.bubble"), input: .selection,
                            promptTemplate: "{input}", output: .previewOnly)
        XCTAssertTrue(AICommandExecutor.isConversationalAsk(ask))
        let emptyAsk = AICommand(name: "Ask", icon: .sfSymbol("text.bubble"), input: .clipboard,
                                 promptTemplate: "", output: .previewOnly)
        XCTAssertTrue(AICommandExecutor.isConversationalAsk(emptyAsk))
        // A preset: a real instruction template → auto-send turn 1.
        let preset = AICommand(name: "Fix", icon: .sfSymbol("wand.and.stars"), input: .selection,
                               promptTemplate: "Fix the grammar:\n\n{input}", output: .replaceSelection)
        XCTAssertFalse(AICommandExecutor.isConversationalAsk(preset))
        // previewOnly but a real instruction → still a preset (it has a question to auto-send).
        let previewPreset = AICommand(name: "Explain", icon: .sfSymbol("text.bubble"), input: .selection,
                                      promptTemplate: "Explain this:\n\n{input}", output: .previewOnly)
        XCTAssertFalse(AICommandExecutor.isConversationalAsk(previewPreset))
    }

    // MARK: - Tool-step approval gate (task 2.8)

    /// A contributor that always needs approval, then runs the routed call per the gate's decision.
    private struct GatedContributor: ToolContributor {
        let name: String
        func descriptors() -> [ToolDescriptor] {
            [ToolDescriptor(name: name, summary: "t", argsSchema: StructuredSchema(name: name, json: "{\"type\":\"object\"}"),
                            writePolicy: .confirm, keywords: [])]
        }
        func canHandle(_ tool: String) -> Bool { tool == name }
        func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
            let decision = await gate.awaitDecision(for: .action(title: "Do it", fields: [ReviewField("What", "thing")],
                                                                 payload: .openTool(tool: name, action: ParsedOpenTool(applicable: true, reason: nil, payload: "p"))))
            switch decision {
            case .approve: return ToolStepResult(tool: name, status: .done, summary: "ran \(name)")
            case .skip: return ToolStepResult(tool: name, status: .declined(reason: "skipped"), summary: "skipped \(name)")
            case .cancel: return ToolStepResult(tool: name, status: .declined(reason: "cancelled"), summary: "cancelled")
            }
        }
    }

    private struct RoutingStub: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        let routeJSON: String
        let answer: String
        final class Box: @unchecked Sendable { var routed = false }
        let box = Box()
        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            AsyncThrowingStream { c in c.yield(Token(answer, isFinal: true)); c.finish() }
        }
        func structured<T: Decodable & Sendable>(_ request: LLMRequest, schema: StructuredSchema, as type: T.Type) async throws -> StructuredOutcome<T> {
            // First call routes to the gated tool; subsequent calls answer plainly (empty tool).
            let json = box.routed ? "{\"tool\":\"\"}" : routeJSON
            box.routed = true
            return .value(try JSONDecoder().decode(T.self, from: Data(json.utf8)))
        }
    }

    func testApprovalGateApproveFiresTheStep() async throws {
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
        let contributor = GatedContributor(name: "doThing")
        let registry = ToolRegistry([contributor])
        let source = StaticCandidateSource(contributor.descriptors())
        let gate = e.makeApprovalGate()
        let loop = AgentLoop(runtime: RoutingStub(routeJSON: "{\"tool\":\"doThing\"}", answer: "Done."),
                             registry: registry, candidateSource: source, gate: gate, maxToolSteps: 4)
        async let result = loop.run(context: RouteContext(messages: [AgentMessage(role: .user, text: "do it")]))
        // The loop pauses awaiting the decision → the executor surfaces `.awaitingApproval`.
        await waitUntil { e.state.isAwaitingApproval }
        XCTAssertTrue(e.approve(), "approve resolves the pending pause")
        let r = await result
        XCTAssertTrue(r.steps.contains { if case .done = $0.status { return true }; return false }, "approve fired the step")
    }

    func testApprovalGateSkipDeclinesTheStep() async throws {
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
        let contributor = GatedContributor(name: "doThing")
        let registry = ToolRegistry([contributor])
        let source = StaticCandidateSource(contributor.descriptors())
        let gate = e.makeApprovalGate()
        let loop = AgentLoop(runtime: RoutingStub(routeJSON: "{\"tool\":\"doThing\"}", answer: "OK."),
                             registry: registry, candidateSource: source, gate: gate, maxToolSteps: 4)
        async let result = loop.run(context: RouteContext(messages: [AgentMessage(role: .user, text: "do it")]))
        await waitUntil { e.state.isAwaitingApproval }
        XCTAssertTrue(e.skip(), "skip resolves the pending pause")
        let r = await result
        XCTAssertTrue(r.steps.contains { if case .declined = $0.status { return true }; return false }, "skip declined the step")
    }

    func testApproveSkipNoOpWhenNothingPending() async throws {
        let e = makeExecutor(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
        XCTAssertFalse(e.approve(), "no pending step → approve is a no-op")
        XCTAssertFalse(e.skip(), "no pending step → skip is a no-op")
    }
}

/// A minimal candidate source advertising a fixed descriptor set (the registry's tools), for the loop tests.
private struct StaticCandidateSource: ToolCandidateSource {
    let all: [ToolDescriptor]
    init(_ all: [ToolDescriptor]) { self.all = all }
    func candidates(for context: RouteContext, limit: Int) -> [ToolDescriptor] { Array(all.prefix(limit)) }
}
