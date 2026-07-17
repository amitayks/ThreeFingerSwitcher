import XCTest
@testable import ThreeFingerSwitcherCore

/// Engine-machine tests ported from the retired conversational canvas (`notch-native-conversations`):
/// the canvas-era seed/float-up/extract/park semantics died with the revert (the launcher canvas is
/// one-shot again — see `AICommandExecutorTests`), and the multi-turn machine they exercised lives on in
/// `NotchSessionEngine`. What survives here: multi-image turns + the vision capability flip, the
/// composer-attachment model's purity, fold-staged-images-then-clear, and the tool-step approval gate
/// (now resolved by the expanded notch panel's Approve/Skip buttons).
@MainActor
final class ConversationalCanvasTests: XCTestCase {

    // MARK: - Harness

    private final class FakeSelection: SelectionProviding {
        /// Scriptable live-clipboard image bytes: `attachClipboardImage()` reads via this seam.
        var clipboardImage: Data?
        func readSelectedText() async -> String? { nil }
        func readClipboardText() -> String? { nil }
        func readClipboardImage() -> Data? { clipboardImage }
        @discardableResult func replaceSelection(_ text: String) async -> Bool { true }
        @discardableResult func pasteAtCursor(_ text: String) async -> Bool { true }
    }
    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        let payload: Data; init(payload: Data) { self.payload = payload }
        func download(_ d: ModelDescriptor, to dest: URL, progress: @Sendable (Double) -> Void) async throws -> Data { progress(1); return payload }
    }
    private func loadedManager(_ runtime: LLMRuntime) async throws -> ModelManager {
        let payload = Data("w".utf8)
        let registry = ModelCatalog(models: [ModelDescriptor(id: "m", displayName: "M", sizeBytes: 1,
            integritySHA: ModelManager.sha256Hex(payload), downloadURL: URL(string: "https://x.invalid/m")!,
            capabilities: [.text, .vision], quantization: .qat4bit)], defaultModelID: "m")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tfs-canvas-\(UUID().uuidString)")
        let m = ModelManager(registry: registry, downloader: FakeDownloader(payload: payload), optedIn: true,
                             storageRoot: root, runtimeFactory: { _ in runtime })
        try await m.downloadAndVerify(registry.models[0]); return m
    }
    private func makeEngine(_ m: ModelManager, selection: FakeSelection? = nil) -> NotchSessionEngine {
        NotchSessionEngine(modelManager: m, selection: selection ?? FakeSelection())
    }
    private func waitUntil(_ p: @MainActor () -> Bool, _ timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !p() && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(p(), "condition not met", file: file, line: line)
    }

    // MARK: - Multi-image turns + the vision capability flip

    func testSendWithImagesAppendsThemAndAssemblyForwardsThem() async throws {
        let stub = StubLLMRuntime(scriptedTurns: [.init(tokens: ["A1"]), .init(tokens: ["A2"])], interTokenDelayNanos: 0)
        let e = makeEngine(try await loadedManager(stub))
        e.startNew()
        e.send("first")
        await waitUntil { e.state == .awaitingTurn && e.conversation?.messages.count == 2 }

        let png1 = Data([0x01, 0x02]); let png2 = Data([0x03, 0x04])
        e.send("more", images: [png1, png2])
        await waitUntil { e.conversation?.messages.count == 4 }
        let userTurn2 = try XCTUnwrap(e.conversation?.messages[2])
        XCTAssertEqual(userTurn2.images, [png1, png2], "BOTH images ride the appended user turn (multi-image)")
        XCTAssertEqual(userTurn2.text, "more")
        let req = try XCTUnwrap(e.assembleRequest())
        XCTAssertEqual(req.images, [png1, png2], "assembleRequest forwards the FULL images array to LLMChatRequest")
    }

    /// Vision flip: after attaching images to turn 2, the turn requests [.text, .vision]. Observed via a
    /// text-only registry: a vision turn against it fails with a clean capability message.
    func testAttachingImagesFlipsTheTurnToVision() async throws {
        let textOnly = StubLLMRuntime(capabilities: [.text], scriptedTurns: [.init(tokens: ["A1"])],
                                      interTokenDelayNanos: 0)
        let payload = Data("w".utf8)
        let registry = ModelCatalog(models: [ModelDescriptor(id: "m", displayName: "M", sizeBytes: 1,
            integritySHA: ModelManager.sha256Hex(payload), downloadURL: URL(string: "https://x.invalid/m")!,
            capabilities: [.text], quantization: .qat4bit)], defaultModelID: "m")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tfs-vflip-\(UUID().uuidString)")
        let m = ModelManager(registry: registry, downloader: FakeDownloader(payload: payload), optedIn: true,
                             storageRoot: root, runtimeFactory: { _ in textOnly })
        try await m.downloadAndVerify(registry.models[0])
        let e = NotchSessionEngine(modelManager: m, selection: FakeSelection())

        e.startNew()
        e.send("text turn")          // turn 1: text only → succeeds against the text model
        await waitUntil { e.state == .awaitingTurn && e.conversation?.messages.count == 2 }

        e.send("look", images: [Data([0x89, 0x50])])   // turn 2: an image → needsVision → asks [.text,.vision]
        await waitUntil { if case .failed = e.state { return true }; return false }
        guard case let .failed(message) = e.state else { return XCTFail("expected .failed (no vision model)") }
        XCTAssertTrue(message.lowercased().contains("vision"),
                      "an image turn requires a vision-capable runtime; the text-only model can't serve it: \(message)")
    }

    // MARK: - Composer attachment model purity (API kept; the notch attach UI is a documented future)

    func testClipboardImageAttachmentPopulatesAndClears() async throws {
        let selection = FakeSelection()
        let png = Data([0xAA, 0xBB])
        selection.clipboardImage = png
        let e = makeEngine(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)), selection: selection)

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
        let e = makeEngine(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)), selection: selection)
        XCTAssertFalse(e.attachClipboardImage(), "no image on the clipboard → no staging, not a failure")
        XCTAssertTrue(e.pendingAttachments.isEmpty)
    }

    /// The staged-attachment send path: staging a clipboard image AND a screenshot then sending text
    /// (the engine folds `pendingAttachments.images` when no explicit images ride the call) puts BOTH
    /// images on the one appended turn, forwards them to assembly, and clears the staging.
    func testSendFoldsMultipleStagedSourcesOntoTurnThenClears() async throws {
        let selection = FakeSelection()
        let clip = Data([0x01, 0x02])
        let shot = Data([0x03, 0x04])
        selection.clipboardImage = clip
        let stub = StubLLMRuntime(scriptedTokens: ["A1"], interTokenDelayNanos: 0)
        let e = makeEngine(try await loadedManager(stub), selection: selection)
        e.startNew()

        XCTAssertTrue(e.attachClipboardImage())
        e.attachScreenshot(shot)
        XCTAssertEqual(e.pendingAttachments.images, [clip, shot], "both sources staged for one turn")
        e.send("look at these")
        await waitUntil { e.state == .awaitingTurn && e.conversation?.messages.count == 2 }

        let turn = try XCTUnwrap(e.conversation?.messages.first)
        XCTAssertEqual(turn.text, "look at these")
        XCTAssertEqual(turn.images, [clip, shot], "BOTH staged images ride the one turn (multi-image)")
        let req = try XCTUnwrap(e.assembleRequest())
        XCTAssertEqual(req.images, [clip, shot], "assembly forwards the full staged-image set to the request")
        XCTAssertTrue(e.pendingAttachments.isEmpty, "the staging clears once the turn folds the images")
    }

    func testSessionResetsClearStagedAttachments() async throws {
        let selection = FakeSelection()
        selection.clipboardImage = Data([0x99])
        let e = makeEngine(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)), selection: selection)
        e.startNew()
        XCTAssertTrue(e.attachClipboardImage())
        e.unbind()
        XCTAssertTrue(e.pendingAttachments.isEmpty, "collapse clears staged-but-unsent attachments")

        // A re-bind also starts with an empty staging area.
        e.bind(AgentConversation(title: "t", messages: [AgentMessage(role: .user, text: "q")]))
        XCTAssertTrue(e.pendingAttachments.isEmpty, "a bound session starts with an empty composer staging")
    }

    // MARK: - Tool-step approval gate (resolved by the expanded panel's Approve/Skip buttons)

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

    private func isAwaitingApproval(_ e: NotchSessionEngine) -> Bool {
        if case .awaitingApproval = e.state { return true }
        return false
    }

    func testApprovalGateApproveFiresTheStep() async throws {
        let e = makeEngine(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
        let contributor = GatedContributor(name: "doThing")
        let registry = ToolRegistry([contributor])
        let source = StaticCandidateSource(contributor.descriptors())
        let gate = e.makeApprovalGate()
        let loop = AgentLoop(runtime: RoutingStub(routeJSON: "{\"tool\":\"doThing\"}", answer: "Done."),
                             registry: registry, candidateSource: source, gate: gate, maxToolSteps: 4)
        async let result = loop.run(context: RouteContext(messages: [AgentMessage(role: .user, text: "do it")]))
        // The loop pauses awaiting the decision → the engine surfaces `.awaitingApproval`.
        await waitUntil { self.isAwaitingApproval(e) }
        XCTAssertTrue(e.approve(), "approve resolves the pending pause")
        let r = await result
        XCTAssertTrue(r.steps.contains { if case .done = $0.status { return true }; return false }, "approve fired the step")
    }

    func testApprovalGateSkipDeclinesTheStep() async throws {
        let e = makeEngine(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
        let contributor = GatedContributor(name: "doThing")
        let registry = ToolRegistry([contributor])
        let source = StaticCandidateSource(contributor.descriptors())
        let gate = e.makeApprovalGate()
        let loop = AgentLoop(runtime: RoutingStub(routeJSON: "{\"tool\":\"doThing\"}", answer: "OK."),
                             registry: registry, candidateSource: source, gate: gate, maxToolSteps: 4)
        async let result = loop.run(context: RouteContext(messages: [AgentMessage(role: .user, text: "do it")]))
        await waitUntil { self.isAwaitingApproval(e) }
        XCTAssertTrue(e.skip(), "skip resolves the pending pause")
        let r = await result
        XCTAssertTrue(r.steps.contains { if case .declined = $0.status { return true }; return false }, "skip declined the step")
    }

    func testApproveSkipNoOpWhenNothingPending() async throws {
        let e = makeEngine(try await loadedManager(StubLLMRuntime(interTokenDelayNanos: 0)))
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
