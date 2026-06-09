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

    /// A scriptable `SelectionProviding`: records every write and serves canned reads.
    private final class FakeSelectionProvider: SelectionProviding {
        var selectedText: String?
        var clipboardText: String?
        var screenRegionData: Data?

        private(set) var replacedWith: [String] = []
        private(set) var pastedAtCursor: [String] = []
        private(set) var screenCaptureCount = 0

        init(selectedText: String? = nil, clipboardText: String? = nil, screenRegionData: Data? = nil) {
            self.selectedText = selectedText
            self.clipboardText = clipboardText
            self.screenRegionData = screenRegionData
        }

        func readSelectedText() async -> String? { selectedText }
        func readClipboardText() -> String? { clipboardText }
        func captureScreenRegion() async -> Data? { screenCaptureCount += 1; return screenRegionData }

        @discardableResult
        func replaceSelection(_ text: String) async -> Bool { replacedWith.append(text); return true }
        func pasteAtCursor(_ text: String) async { pastedAtCursor.append(text) }
    }

    /// A fake `TaskDispatching` for the executor's new two-stage seam: `prepare` records the requested
    /// (kind, prompt, source) and returns a scripted review; `execute` records the executed review's
    /// preview title so a test can assert the side effect fired exactly once, only on commit.
    private final class FakeTaskDispatcher: TaskDispatching {
        private(set) var prepared: [(kind: TaskKind, prompt: String, source: TaskSource)] = []
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

        func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource) async -> TaskReview {
            prepared.append((kind, resolvedPrompt, source))
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

    // MARK: - Screen-region with no capture surfaces no-input

    func testScreenRegionWithNoCaptureSurfacesNoInput() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["nope"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(runtime: stub, capabilities: [.text, .vision])
        let selection = FakeSelectionProvider(screenRegionData: nil) // capture unavailable
        let executor = AICommandExecutor(modelManager: manager, selection: selection,
                                         dispatcher: FakeTaskDispatcher())

        let command = AICommand(name: "Describe", icon: .emoji("👁"), input: .screenRegion,
                                promptTemplate: "What's here?", output: .previewOnly)
        executor.fire(command)
        await waitUntil { executor.state == .noInput }
        XCTAssertEqual(executor.state, .noInput, "a screen-region command with no capture is no-input")
    }
}
