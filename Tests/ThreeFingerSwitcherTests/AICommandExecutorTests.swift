import XCTest
import Combine
@testable import ThreeFingerSwitcherCore

/// Tests for the command executor (spec: "Command input acquisition" / "In-place output routing";
/// tasks phase 9) against the stub runtime + a fake selection provider + a fake task dispatcher: the
/// full in-place pipeline, selection→clipboard fallback, the no-input path, previewOnly writing
/// nothing, replaceSelection routing to the writer, cancellation, and a task path routing through the
/// dispatcher with the stored `confirmBeforeRun` honored.
@MainActor
final class AICommandExecutorTests: XCTestCase {

    // MARK: - Fakes

    /// A scriptable `SelectionProviding`: records every write and serves canned reads. `replaceLands` /
    /// `pasteLands` script whether a write actually LANDED (so the non-landed → `.failed` honesty is
    /// testable); `screenCaptureOutcome` overrides the derived capture result (e.g. `.permissionDenied`).
    private final class FakeSelectionProvider: SelectionProviding {
        var selectedText: String?
        var clipboardText: String?
        var clipboardImageData: Data?
        var replaceLands = true
        var pasteLands = true

        private(set) var replacedWith: [String] = []
        private(set) var pastedAtCursor: [String] = []

        init(selectedText: String? = nil, clipboardText: String? = nil) {
            self.selectedText = selectedText
            self.clipboardText = clipboardText
        }

        func readSelectedText() async -> String? { selectedText }
        func readClipboardText() -> String? { clipboardText }
        func readClipboardImage() -> Data? { clipboardImageData }
        // Screen-region capture is no longer on this seam: the picker captures the region and the
        // capture outcome is handed to `executor.fire(_:screenCapture:)`.

        @discardableResult
        func replaceSelection(_ text: String) async -> Bool { replacedWith.append(text); return replaceLands }
        @discardableResult
        func pasteAtCursor(_ text: String) async -> Bool { pastedAtCursor.append(text); return pasteLands }
    }

    /// A fake `TaskDispatching` for the executor's new two-stage seam: `prepare` records the requested
    /// (kind, prompt, source) and returns a scripted review; `execute` records the executed review's
    /// preview title so a test can assert the side effect fired exactly once, only on commit.
    private final class FakeTaskDispatcher: TaskDispatching {
        private(set) var prepared: [(kind: TaskKind, prompt: String, source: TaskSource, reasoning: Bool)] = []
        private(set) var executed: [TaskReview] = []
        /// The review `prepare` returns. Defaults to a ready `.action` so the happy path lands in
        /// `.reviewingAction` / `.committed`.
        var reviewToReturn: TaskReview = .action(title: "Task",
                                                 fields: [ReviewField("Field", "Value")],
                                                 payload: .openTool(tool: "x",
                                                                    action: ParsedOpenTool(applicable: true,
                                                                                           reason: nil,
                                                                                           payload: "p")))
        var executeError: Error?

        func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource,
                     reasoning: Bool) async -> TaskReview {
            prepared.append((kind, resolvedPrompt, source, reasoning))
            return reviewToReturn
        }

        func execute(_ review: TaskReview) async throws {
            if let error = executeError { throw error }
            executed.append(review)
        }
    }

    // MARK: - ModelManager helper

    /// A `ModelManager` that is opted-in, verified, and whose `runtimeFactory` returns `runtime`, so
    /// `runtime(requiring:)` resolves to exactly that scripted stub.
    private func loadedManager(runtime: StubLLMRuntime,
                              capabilities: Set<Modality> = [.text, .vision]) async throws -> ModelManager {
        let payload = Data("weights".utf8)
        let registry = ModelRegistry(
            models: [ModelDescriptor(
                id: "test-model",
                displayName: "Test Model",
                sizeBytes: Int64(payload.count),
                integritySHA: ModelManager.sha256Hex(payload),
                downloadURL: URL(string: "https://models.invalid/test-model")!,
                capabilities: capabilities,
                quantization: .qat4bit
            )],
            defaultModelID: "test-model"
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-executor-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = ModelManager(
            registry: registry,
            downloader: FakeDownloader(payload: payload),
            optedIn: true,
            storageRoot: root,
            runtimeFactory: { _ in runtime }
        )
        try await manager.downloadAndVerify(registry.models[0])
        return manager
    }

    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        let payload: Data
        init(payload: Data) { self.payload = payload }
        func download(_ descriptor: ModelDescriptor, to destination: URL,
                      progress: @Sendable (Double) -> Void) async throws -> Data {
            progress(1.0); return payload
        }
    }

    /// A runtime that records the last `LLMRequest` it was handed, so a test can assert the executor
    /// propagated `reasoning` onto the text-path request. Echoes the prompt as a single token.
    private final class CapturingLLMRuntime: LLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text, .vision]
        private(set) var lastRequest: LLMRequest?

        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            lastRequest = request
            return AsyncThrowingStream { continuation in
                continuation.yield(Token(request.prompt, isFinal: true))
                continuation.finish()
            }
        }

        func structured<T: Decodable & Sendable>(
            _ request: LLMRequest, schema: StructuredSchema, as type: T.Type
        ) async throws -> StructuredOutcome<T> {
            lastRequest = request
            throw RuntimeError.couldNotProduceValid(attempts: 1)
        }
    }

    /// A `ModelManager` opted-in + verified whose `runtimeFactory` returns `runtime` — variant of
    /// `loadedManager(runtime:)` that accepts any `LLMRuntime` (used by the reasoning-propagation test).
    private func loadedManager(anyRuntime runtime: LLMRuntime) async throws -> ModelManager {
        let payload = Data("weights".utf8)
        let registry = ModelRegistry(
            models: [ModelDescriptor(
                id: "test-model",
                displayName: "Test Model",
                sizeBytes: Int64(payload.count),
                integritySHA: ModelManager.sha256Hex(payload),
                downloadURL: URL(string: "https://models.invalid/test-model")!,
                capabilities: [.text, .vision],
                quantization: .qat4bit
            )],
            defaultModelID: "test-model"
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-executor-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = ModelManager(
            registry: registry,
            downloader: FakeDownloader(payload: payload),
            optedIn: true,
            storageRoot: root,
            runtimeFactory: { _ in runtime }
        )
        try await manager.downloadAndVerify(registry.models[0])
        return manager
    }

    // MARK: - Reasoning flag propagation (text path)

    func testReasoningFlagPropagatesToTextRequest() async throws {
        let runtime = CapturingLLMRuntime()
        let manager = try await loadedManager(anyRuntime: runtime)
        let selection = FakeSelectionProvider(selectedText: "input")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher(),
                                         reasoning: { true })

        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(runtime.lastRequest?.reasoning, true,
                       "the executor sets request.reasoning from the injected closure")
    }

    // MARK: - Per-command reasoning override (text path): the command's override wins over the global

    /// A per-command `.off` override beats a global default of TRUE: the text request reasons FALSE.
    func testCommandReasoningOffOverridesGlobalTrue() async throws {
        let runtime = CapturingLLMRuntime()
        let manager = try await loadedManager(anyRuntime: runtime)
        let selection = FakeSelectionProvider(selectedText: "input")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher(),
                                         reasoning: { true })   // global default ON

        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly, reasoning: .off)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(runtime.lastRequest?.reasoning, false,
                       "a per-command .off override forces reasoning off even when the global default is on")
    }

    /// A per-command `.on` override beats a global default of FALSE: the text request reasons TRUE.
    func testCommandReasoningOnOverridesGlobalFalse() async throws {
        let runtime = CapturingLLMRuntime()
        let manager = try await loadedManager(anyRuntime: runtime)
        let selection = FakeSelectionProvider(selectedText: "input")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher(),
                                         reasoning: { false })   // global default OFF

        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly, reasoning: .on)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(runtime.lastRequest?.reasoning, true,
                       "a per-command .on override forces reasoning on even when the global default is off")
    }

    /// An absent per-command override (`nil`) follows the global default on the text request.
    func testCommandReasoningNilFollowsGlobalDefault() async throws {
        let runtime = CapturingLLMRuntime()
        let manager = try await loadedManager(anyRuntime: runtime)
        let selection = FakeSelectionProvider(selectedText: "input")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher(),
                                         reasoning: { true })   // global default ON

        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly)  // no override
        XCTAssertNil(command.reasoning, "a fresh command has no reasoning override")
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(runtime.lastRequest?.reasoning, true,
                       "an absent override follows the injected global default")
    }

    // MARK: - Per-command reasoning override (task path): the executor passes the resolved value

    /// The executor resolves reasoning per command and passes it into `dispatcher.prepare(..., reasoning:)`:
    /// a task command with `.on` + a global default of FALSE prepares with reasoning TRUE.
    func testTaskPathReceivesPerCommandResolvedReasoning() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused for tasks"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "lunch with sam tomorrow")
        let dispatcher = FakeTaskDispatcher()
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher,
                                         reasoning: { false })   // global default OFF

        let command = AICommand(name: "Add to Calendar", icon: .emoji("📅"), input: .selection,
                                promptTemplate: "{input}", output: .runTask(.addToCalendar),
                                confirmBeforeRun: false, reasoning: .on)
        executor.fire(command)
        await waitUntil { executor.state == .committed }
        let prep = try XCTUnwrap(dispatcher.prepared.first)
        XCTAssertTrue(prep.reasoning,
                      "a per-command .on override is passed into prepare even when the global default is off")
    }

    /// Spin the run loop until `predicate` holds or a deadline elapses (the executor streams off a
    /// detached Task; this lets the test observe terminal/observable states without sleeping fixed).
    private func waitUntil(_ predicate: @MainActor () -> Bool,
                           timeout: TimeInterval = 2.0,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        }
        XCTAssertTrue(predicate(), "condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - In-place pipeline: replaceSelection routes to the writer

    func testReplaceSelectionPipelineRoutesToWriter() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Fixed ", "text"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "teh txt")
        let dispatcher = FakeTaskDispatcher()
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        let command = AICommand(name: "Fix", icon: .emoji("✅"), input: .selection,
                                promptTemplate: "Fix: {input}", output: .replaceSelection)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(executor.state, .ready(result: "Fixed text"))

        try await executor.commit()
        XCTAssertEqual(executor.state, .committed)
        XCTAssertEqual(selection.replacedWith, ["Fixed text"], "the result is written via replaceSelection")
        XCTAssertTrue(dispatcher.prepared.isEmpty, "an in-place output never prepares a task")
        XCTAssertTrue(dispatcher.executed.isEmpty, "an in-place output never executes a task")
    }

    // MARK: - Selection → clipboard fallback

    func testEmptySelectionFallsBackToClipboard() async throws {
        let stub = StubLLMRuntime(scriptedTokens: [], interTokenDelayNanos: 0) // echoes the prompt
        let manager = try await loadedManager(runtime: stub)
        // No selection, but clipboard has text — the executor must use the clipboard.
        let selection = FakeSelectionProvider(selectedText: nil, clipboardText: "from clipboard")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        // The stub echoes its prompt, which is the resolved template = the acquired input.
        XCTAssertEqual(executor.state, .ready(result: "from clipboard"),
                       "an empty selection falls back to the clipboard text")
    }

    // MARK: - No input

    func testNoInputSurfacesAndDoesNotInvokeModel() async throws {
        // A generate that would fail loudly if reached, proving the model is NOT invoked.
        let stub = StubLLMRuntime(scriptedTokens: ["SHOULD NOT APPEAR"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: nil, clipboardText: nil) // nothing anywhere
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Fix", icon: .emoji("✅"), input: .selection,
                                promptTemplate: "Fix: {input}", output: .replaceSelection)
        executor.fire(command)
        await waitUntil { executor.state == .noInput }
        XCTAssertEqual(executor.state, .noInput)
        XCTAssertTrue(selection.replacedWith.isEmpty, "no model run means no output write")
    }

    // MARK: - Clipboard image (vision input)

    func testClipboardImageFeedsVisionRequest() async throws {
        let runtime = CapturingLLMRuntime()
        let manager = try await loadedManager(anyRuntime: runtime)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])   // stand-in PNG bytes
        let selection = FakeSelectionProvider()
        selection.clipboardImageData = imageBytes
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Describe Clipboard Image", icon: .emoji("🖼"), input: .clipboardImage,
                                promptTemplate: "What is in this image?", output: .previewOnly)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(runtime.lastRequest?.image, imageBytes,
                       "the clipboard image is carried on the request as the vision image input")
        XCTAssertEqual(runtime.lastRequest?.requiresVision, true, "the request is a vision request")
    }

    func testClipboardImageWithNoImageSurfacesNoInputAndDoesNotInvokeModel() async throws {
        let runtime = CapturingLLMRuntime()
        let manager = try await loadedManager(anyRuntime: runtime)
        let selection = FakeSelectionProvider()   // clipboardImageData is nil — nothing on the clipboard
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Describe Clipboard Image", icon: .emoji("🖼"), input: .clipboardImage,
                                promptTemplate: "What is in this image?", output: .previewOnly)
        executor.fire(command)
        await waitUntil { executor.state == .noInput }
        XCTAssertEqual(executor.state, .noInput, "no clipboard image → a clean no-input state")
        XCTAssertNil(runtime.lastRequest, "the model is not invoked when there is no image")
    }

    // MARK: - previewOnly writes nothing

    func testPreviewOnlyCommitsWithoutWriting() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["a summary"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "long text")
        let dispatcher = FakeTaskDispatcher()
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        let command = AICommand(name: "Summarize", icon: .emoji("📝"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        try await executor.commit()

        XCTAssertEqual(executor.state, .committed)
        XCTAssertTrue(selection.replacedWith.isEmpty, "previewOnly never replaces selection")
        XCTAssertTrue(selection.pastedAtCursor.isEmpty, "previewOnly never pastes")
        XCTAssertTrue(dispatcher.prepared.isEmpty, "previewOnly never prepares a task")
        XCTAssertTrue(dispatcher.executed.isEmpty, "previewOnly never executes a task")
    }

    // MARK: - Cancellation (horizontal discard swipe)

    func testCancellationStopsGeneration() async throws {
        // A slow stream so cancel lands mid-flight.
        let stub = StubLLMRuntime(scriptedTokens: Array(repeating: "x", count: 50),
                                  interTokenDelayNanos: 5_000_000) // 5 ms each
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "input")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Slow", icon: .emoji("🐌"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly)
        executor.fire(command)
        await waitUntil { if case .streaming = executor.state { return true }; return false }
        executor.cancel()
        XCTAssertEqual(executor.state, .idle, "cancel resets to idle and writes nothing")

        // Deterministic proof generation truly stopped: the runtime observed and honored
        // cancellation (no wall-clock sleep — waitUntil polls a condition with a failure-only deadline).
        await waitUntil { stub.observedCancellation }
        XCTAssertTrue(stub.observedCancellation, "the runtime observed and honored cancellation")
        XCTAssertEqual(executor.state, .idle, "state stays idle after cancel (no ready appears)")
    }

    // MARK: - Show the model's thinking: channel split (thinking vs response)

    /// The runtime streams `.thinking`-channel tokens BEFORE the `.response` tokens. The executor must
    /// accumulate the reasoning into the observable `thinking` (so the canvas's collapsible section can
    /// render it live) while STREAMING/COMMITTING only the response — the thinking must never appear in
    /// the ready result nor in what commit routes to the app.
    func testThinkingStreamsSeparatelyAndOnlyResponseCommits() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Fixed ", "text"],
                                  scriptedThinking: ["Let me think… ", "checking grammar"],
                                  interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "teh txt")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Fix", icon: .emoji("✅"), input: .selection,
                                promptTemplate: "Fix: {input}", output: .replaceSelection)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }

        // The reasoning accumulated into `thinking`...
        XCTAssertEqual(executor.thinking, "Let me think… checking grammar",
                       "every .thinking-channel token accumulates into the observable thinking")
        // ...but the result is RESPONSE-ONLY (no thinking text leaked in).
        XCTAssertEqual(executor.state, .ready(result: "Fixed text"),
                       "the ready result is the response only — thinking never appears in it")
        XCTAssertFalse(executor.state == .ready(result: "Let me think… checking grammarFixed text"),
                       "thinking is not prepended to the committed result")

        // And commit routes the RESPONSE only to the app — the thinking is never written.
        try await executor.commit()
        XCTAssertEqual(executor.state, .committed)
        XCTAssertEqual(selection.replacedWith, ["Fixed text"],
                       "commit writes the response only; the thinking is never routed to the app")
    }

    /// A fresh fire and a cancel must each CLEAR the previously-streamed thinking, so a re-run/discard
    /// never shows stale reasoning.
    func testThinkingResetsOnNewFireAndOnCancel() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["done"],
                                  scriptedThinking: ["reasoning A"],
                                  interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "input")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())
        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly)

        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(executor.thinking, "reasoning A", "the first run accumulates its reasoning")

        // A cancel (horizontal discard) clears the thinking immediately.
        executor.cancel()
        XCTAssertEqual(executor.thinking, "", "cancel clears the streamed thinking")

        // A fresh fire also starts with empty thinking before its own reasoning streams in.
        let stub2 = StubLLMRuntime(scriptedTokens: ["done2"],
                                   scriptedThinking: ["reasoning B"],
                                   interTokenDelayNanos: 0)
        let manager2 = try await loadedManager(runtime: stub2)
        let executor2 = AICommandExecutor(modelManager: manager2, selection: selection,
                                          dispatcher: FakeTaskDispatcher())
        executor2.fire(command)
        await waitUntil { if case .ready = executor2.state { return true }; return false }
        XCTAssertEqual(executor2.thinking, "reasoning B",
                       "a fresh fire shows only its own reasoning, never the prior run's")
    }

    // MARK: - Commit-vs-ignore decision (down-swipe gate)

    func testStateIsCommittableOnlyForReadyResults() {
        // `resolveCanvasCommit` (the DOWN-swipe commit path) commits only a committable state; a DOWN
        // swipe in any other state is IGNORED — the user waits, and only a horizontal discard swipe
        // cancels generation. (`.reviewingAction` is also committable — exercised by the task-path tests.)
        XCTAssertTrue(AICommandExecutor.State.ready(result: "x").isCommittable)
        XCTAssertFalse(AICommandExecutor.State.idle.isCommittable)
        XCTAssertFalse(AICommandExecutor.State.loadingModel.isCommittable)
        XCTAssertFalse(AICommandExecutor.State.noInput.isCommittable)
        XCTAssertFalse(AICommandExecutor.State.streaming(partial: "half").isCommittable,
                       "a DOWN swipe while still streaming must NOT commit — it is ignored (the user waits); only a horizontal swipe discards")
        XCTAssertFalse(AICommandExecutor.State.declined(reason: "not a meeting").isCommittable)
        XCTAssertFalse(AICommandExecutor.State.failed(message: "boom").isCommittable)
        XCTAssertFalse(AICommandExecutor.State.committed.isCommittable)
    }

    // MARK: - Whitespace-only input counts as empty

    func testWhitespaceOnlyInputSurfacesNoInput() async throws {
        // Regression: a whitespace-only selection AND clipboard count as empty → .noInput, and the
        // model is never run on effectively-empty content.
        let stub = StubLLMRuntime(scriptedTokens: ["SHOULD NOT APPEAR"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "   ", clipboardText: "\n\t  ")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())
        let command = AICommand(name: "Blank", icon: .emoji("⬜"), input: .selection,
                                promptTemplate: "{input}", output: .replaceSelection)
        executor.fire(command)
        await waitUntil { executor.state == .noInput }
        XCTAssertEqual(executor.state, .noInput, "whitespace-only selection+clipboard surfaces no-input")
        XCTAssertTrue(selection.replacedWith.isEmpty, "the model is never run on whitespace-only input")
    }

    // MARK: - Task path: review SKIPPED when confirmBeforeRun is OFF (stored value honored)

    func testTaskOutputWithConfirmOffExecutesWithoutReviewGate() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused for tasks"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "lunch with sam tomorrow")
        let dispatcher = FakeTaskDispatcher()
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        // A trusted side-effecting command: the user disabled confirmation. It must be honored — the
        // side effect commits directly (prepare → execute), with NO armed-confirmation review gate.
        let command = AICommand(name: "Add to Calendar", icon: .emoji("📅"), input: .selection,
                                promptTemplate: "{input}", output: .runTask(.addToCalendar),
                                confirmBeforeRun: false)
        XCTAssertFalse(command.confirmBeforeRun)

        executor.fire(command)
        // With review OFF, the executor commits the side effect itself — no separate commit() call.
        await waitUntil { executor.state == .committed }
        XCTAssertEqual(executor.state, .committed)

        XCTAssertEqual(dispatcher.prepared.count, 1, "the task output prepares through the dispatcher")
        let prep = try XCTUnwrap(dispatcher.prepared.first)
        XCTAssertEqual(prep.kind, .addToCalendar, "the calendar task kind is routed to prepare")
        XCTAssertEqual(prep.prompt, "lunch with sam tomorrow", "the resolved prompt is handed to prepare")
        XCTAssertEqual(dispatcher.executed.count, 1, "the side effect fires exactly once (review skipped)")
        XCTAssertTrue(selection.replacedWith.isEmpty, "a task output writes nothing in-place")
    }

    // MARK: - Task path: review SHOWN when confirmBeforeRun is ON; fires only on commit

    func testSendToOutputShowsReviewThenFiresOnCommit() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "note this")
        let dispatcher = FakeTaskDispatcher()
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        let command = AICommand(name: "Send", icon: .emoji("📤"), input: .selection,
                                promptTemplate: "{input}", output: .sendTo(.shortcut(name: "Log")))
        XCTAssertTrue(command.confirmBeforeRun, "send-to defaults confirm ON")

        executor.fire(command)
        // Review ON → land in the armed-confirmation state; NOTHING has fired yet.
        await waitUntil { if case .reviewingAction = executor.state { return true }; return false }
        XCTAssertEqual(dispatcher.prepared.first?.kind, .sendTo(.shortcut(name: "Log")),
                       "a sendTo output maps to the sendTo task kind in prepare")
        XCTAssertTrue(dispatcher.executed.isEmpty, "no side effect fires while only reviewing")

        // The commit (down-swipe) fires the reviewed side effect.
        try await executor.commit()
        XCTAssertEqual(executor.state, .committed)
        XCTAssertEqual(dispatcher.executed.count, 1, "the reviewed side effect fires on commit")
    }

    // MARK: - Task path: discard while reviewing fires NO side effect

    func testDiscardWhileReviewingFiresNoSideEffect() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "note this")
        let dispatcher = FakeTaskDispatcher()
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        let command = AICommand(name: "Send", icon: .emoji("📤"), input: .selection,
                                promptTemplate: "{input}", output: .sendTo(.shortcut(name: "Log")))
        executor.fire(command)
        await waitUntil { if case .reviewingAction = executor.state { return true }; return false }

        executor.cancel()   // discard before committing
        XCTAssertEqual(executor.state, .idle, "discard resets to idle")
        XCTAssertTrue(dispatcher.executed.isEmpty, "discarding a reviewed task fires no side effect")
    }

    // MARK: - Task path: a declined review surfaces .declined and fires nothing

    func testTaskDeclineSurfacesDeclinedAndFiresNothing() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "not a meeting at all")
        let dispatcher = FakeTaskDispatcher()
        dispatcher.reviewToReturn = .declined(reason: "This text is not a meeting")
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        let command = AICommand(name: "Add to Calendar", icon: .emoji("📅"), input: .selection,
                                promptTemplate: "{input}", output: .runTask(.addToCalendar))
        executor.fire(command)
        await waitUntil { if case .declined = executor.state { return true }; return false }
        XCTAssertEqual(executor.state, .declined(reason: "This text is not a meeting"))
        XCTAssertTrue(dispatcher.executed.isEmpty, "a declined task fires no side effect")
    }

    // MARK: - Task path: an unavailable review surfaces .failed (no malformed side effect)

    func testTaskUnavailableSurfacesFailedAndFiresNothing() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "lunch")
        let dispatcher = FakeTaskDispatcher()
        dispatcher.reviewToReturn = .unavailable(reason: "Couldn't produce a valid action.")
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        let command = AICommand(name: "Add to Calendar", icon: .emoji("📅"), input: .selection,
                                promptTemplate: "{input}", output: .runTask(.addToCalendar))
        executor.fire(command)
        await waitUntil { if case .failed = executor.state { return true }; return false }
        XCTAssertEqual(executor.state, .failed(message: "Couldn't produce a valid action."))
        XCTAssertTrue(dispatcher.executed.isEmpty, "an unavailable task dispatches no side effect")
    }

    // MARK: - Task path: a throwing commit surfaces .failed with a human message (Fix 3 + Fix 2)

    func testReviewedCommitThatThrowsSurfacesFailedWithHumanMessage() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "lunch with sam tomorrow")
        let dispatcher = FakeTaskDispatcher()
        // prepare returns the default ready `.action`; execute THROWS the calendar-denied error (the
        // default-calendar path is armed-confirmation, so this lands on commit).
        dispatcher.executeError = TaskError.calendarPermissionDenied
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        // confirmBeforeRun ON (default) → drive to the armed-confirmation review first.
        let command = AICommand(name: "Add to Calendar", icon: .emoji("📅"), input: .selection,
                                promptTemplate: "{input}", output: .runTask(.addToCalendar))
        XCTAssertTrue(command.confirmBeforeRun, "calendar defaults confirm ON")
        executor.fire(command)
        await waitUntil { if case .reviewingAction = executor.state { return true }; return false }
        XCTAssertTrue(dispatcher.executed.isEmpty, "nothing fires while only reviewing")

        // commit() must rethrow the error AND leave the executor in .failed with a readable message.
        var thrown: Error?
        do {
            try await executor.commit()
            XCTFail("commit should rethrow the side-effect error")
        } catch {
            thrown = error
        }
        XCTAssertEqual(thrown as? TaskError, .calendarPermissionDenied, "commit rethrows the task error")

        guard case let .failed(message) = executor.state else {
            return XCTFail("a throwing commit surfaces .failed, got \(executor.state)")
        }
        XCTAssertTrue(message.contains("Calendar"),
                      "the message is human-facing and mentions Calendar")
        XCTAssertNotEqual(message, "calendarPermissionDenied",
                          "NOT the raw enum case name (Fix 2 surfaces the LocalizedError description)")
    }

    // MARK: - Runtime language parameter: persisted default + in-canvas re-run

    func testActiveLanguageResolvesDeclaredDefaultAtColdStart() async throws {
        let stub = StubLLMRuntime(scriptedTokens: [], interTokenDelayNanos: 0) // echoes the prompt
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "hello")
        var store: [UUID: String] = [:]
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher(),
                                         loadLanguage: { store[$0] }, saveLanguage: { store[$0] = $1 })
        let command = AICommand(name: "Translate", icon: .emoji("🌍"), input: .selection,
                                promptTemplate: "Translate to {lang}:\n{input}", output: .previewOnly,
                                runtimeParameter: .language(default: "English"))
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(executor.activeLanguage, "English", "cold start uses the declared default")
        XCTAssertEqual(executor.state, .ready(result: "Translate to English:\nhello"),
                       "{lang} resolves to the active language in the streamed prompt")
    }

    func testSetLanguagePersistsAndRetranslatesInPlace() async throws {
        let stub = StubLLMRuntime(scriptedTokens: [], interTokenDelayNanos: 0) // echoes the prompt
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "hello")
        var store: [UUID: String] = [:]
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher(),
                                         loadLanguage: { store[$0] }, saveLanguage: { store[$0] = $1 })
        let command = AICommand(name: "Translate", icon: .emoji("🌍"), input: .selection,
                                promptTemplate: "Translate to {lang}:\n{input}", output: .previewOnly,
                                runtimeParameter: .language(default: "English"))
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }

        // Repick a language in the canvas: re-runs in place AND persists for the next run.
        executor.setLanguage("Hebrew")
        await waitUntil { executor.state == .ready(result: "Translate to Hebrew:\nhello") }
        XCTAssertEqual(executor.activeLanguage, "Hebrew")
        XCTAssertEqual(store[command.id], "Hebrew", "the choice is persisted per command")

        // A fresh fire now defaults to the remembered language (the next-run default).
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(executor.activeLanguage, "Hebrew", "next run defaults to the remembered language")
        XCTAssertEqual(executor.state, .ready(result: "Translate to Hebrew:\nhello"))
    }

    func testSetLanguageIsIgnoredWithoutARuntimeParameter() async throws {
        let stub = StubLLMRuntime(scriptedTokens: [], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "hello")
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())
        let command = AICommand(name: "Echo", icon: .emoji("🔁"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly) // no runtimeParameter
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertNil(executor.activeLanguage, "a command with no runtime parameter has no active language")
        executor.setLanguage("Hebrew")  // must be a no-op
        XCTAssertNil(executor.activeLanguage, "setLanguage is ignored without a language parameter")
        XCTAssertEqual(executor.state, .ready(result: "hello"), "the result is unchanged")
    }

    // MARK: - Screen-region capture outcomes (picker pre-supplies the capture)

    func testScreenRegionWithUnavailableCaptureSurfacesNoInput() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["nope"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub, capabilities: [.text, .vision])
        let selection = FakeSelectionProvider()
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Describe", icon: .emoji("👁"), input: .screenRegion,
                                promptTemplate: "What's here?", output: .previewOnly)
        executor.fire(command, screenCapture: .unavailable)   // picker captured nothing
        await waitUntil { executor.state == .noInput }
        XCTAssertEqual(executor.state, .noInput, "an unavailable capture is no-input")
    }

    func testScreenRegionWithNoSuppliedCaptureSurfacesNoInput() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["nope"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub, capabilities: [.text, .vision])
        let selection = FakeSelectionProvider()
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Describe", icon: .emoji("👁"), input: .screenRegion,
                                promptTemplate: "What's here?", output: .previewOnly)
        executor.fire(command)   // no capture supplied at all (defensive) → no-input, no model run
        await waitUntil { executor.state == .noInput }
        XCTAssertEqual(executor.state, .noInput, "a screen-region fire with no supplied capture is no-input")
    }

    func testScreenRegionWithCapturedImageStreamsResult() async throws {
        let runtime = CapturingLLMRuntime()
        let manager = try await loadedManager(anyRuntime: runtime)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x09])
        let executor = AICommandExecutor(modelManager: manager, selection: FakeSelectionProvider(),
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Describe", icon: .emoji("👁"), input: .screenRegion,
                                promptTemplate: "What's here?", output: .previewOnly)
        executor.fire(command, screenCapture: .captured(png))
        await waitUntil { if case .ready = executor.state { return true }; return false }
        XCTAssertEqual(runtime.lastRequest?.image, png, "the picker's captured region is the vision image")
        XCTAssertEqual(runtime.lastRequest?.requiresVision, true)
    }

    // MARK: - Honesty (D5): a non-landed replaceSelection surfaces .failed, not .committed

    func testNonLandedReplaceSelectionSurfacesFailed() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Fixed text"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "teh txt")
        selection.replaceLands = false   // the write does NOT actually land in the app
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Fix", icon: .emoji("✅"), input: .selection,
                                promptTemplate: "Fix: {input}", output: .replaceSelection)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        try await executor.commit()

        guard case let .failed(message) = executor.state else {
            return XCTFail("a write that didn't land must surface .failed, got \(executor.state)")
        }
        XCTAssertFalse(message.isEmpty, "the failure carries a clean message")
        XCTAssertTrue(selection.replacedWith == ["Fixed text"], "the write was attempted")
    }

    func testNonLandedPasteSurfacesFailed() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["summary"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "long text")
        selection.pasteLands = false
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())
        let command = AICommand(name: "Paste", icon: .emoji("📋"), input: .selection,
                                promptTemplate: "{input}", output: .pasteAtCursor)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        try await executor.commit()
        guard case .failed = executor.state else {
            return XCTFail("a paste that didn't land must surface .failed, got \(executor.state)")
        }
    }

    // MARK: - Honesty (D5): a sink throw surfaces a clean task-failed message (never a raw dump)

    func testSinkFailureSurfacesCleanTaskFailedMessage() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["unused"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub)
        let selection = FakeSelectionProvider(selectedText: "note this")
        let dispatcher = FakeTaskDispatcher()
        dispatcher.executeError = TaskError.sinkFailed("Could not save the note to “Roadmap”.")
        let executor = AICommandExecutor(modelManager: manager, selection: selection, dispatcher: dispatcher)

        let command = AICommand(name: "Save", icon: .emoji("💾"), input: .selection,
                                promptTemplate: "{input}", output: .runTask(.saveToProject(project: "Roadmap")))
        executor.fire(command)
        await waitUntil { if case .reviewingAction = executor.state { return true }; return false }
        _ = try? await executor.commit()
        guard case let .failed(message) = executor.state else {
            return XCTFail("a thrown sink failure must surface .failed, got \(executor.state)")
        }
        XCTAssertEqual(message, "Could not save the note to “Roadmap”.",
                       "the clean sinkFailed message is shown verbatim, not a raw error dump")
    }

    // MARK: - Honesty (D5): a Screen-Recording permission gap names the permission, not "no input"

    func testScreenRecordingPermissionGapSurfacesFailedNamingThePermission() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["nope"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub, capabilities: [.text, .vision])
        let selection = FakeSelectionProvider()
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())
        let command = AICommand(name: "Describe", icon: .emoji("👁"), input: .screenRegion,
                                promptTemplate: "What's here?", output: .previewOnly)
        executor.fire(command, screenCapture: .permissionDenied)   // picker hit a Screen-Recording gap
        await waitUntil { if case .failed = executor.state { return true }; return false }
        guard case let .failed(message) = executor.state else {
            return XCTFail("a permission gap must surface .failed (not .noInput), got \(executor.state)")
        }
        XCTAssertTrue(message.contains("Screen Recording"), "the message names the missing permission")
    }
}
