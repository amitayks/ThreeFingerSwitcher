import Foundation
import Combine

/// Orchestrates one AI command fire end-to-end (spec: "Command input acquisition" + "In-place output
/// routing"; tasks phase 9), behind seams so the slices stay decoupled: it talks to the model only
/// through `ModelManager` → `LLMRuntime`, to the front app only through `SelectionProviding`, and to
/// side effects only through `TaskDispatching`. It never sees a concrete model, selection service, or
/// task dispatcher.
///
/// The fire is two-stage (design D4): `fire(_:)` acquires input, resolves the template, selects the
/// model, and STREAMS the result into observable `state` (so slice 5's canvas can render live and a
/// horizontal discard swipe can cancel); `commit()` then routes the ready result per the command's output target.
///
/// `@MainActor` (and `ObservableObject`) because it holds observable UI state, matching the project's
/// convention (`AppSettings`, `ClipboardStore`, `ModelManager`).
@MainActor
final class AICommandExecutor: ObservableObject {

    /// The executor's observable state — the contract slice 5's canvas binds to.
    enum State: Equatable {
        /// Nothing in flight.
        case idle
        /// Resolving + loading the model (a visible state, never a silent block — design D4).
        case loadingModel
        /// An input-requiring command got no input; the model was NOT invoked (spec: "No input
        /// available is surfaced").
        case noInput
        /// Generation in flight; `partial` is the text accumulated so far.
        case streaming(partial: String)
        /// A finished, uncommitted result awaiting the commit (down-swipe) for in-place outputs.
        case ready(result: String)
        /// A side-effecting task's parsed action awaiting the armed-confirmation commit (design D6):
        /// the review carries the preview `fields` slice 5 renders. Reached ONLY when the command's
        /// `confirmBeforeRun` is on; when off, the side effect commits directly to `.committed`.
        case reviewingAction(TaskReview)
        /// A structured/task path the model declined (design D2) — carries the reason.
        case declined(reason: String)
        /// A typed failure with a human-readable message.
        case failed(message: String)
        /// Committed and done (in-place written or task dispatched).
        case committed

        /// Whether a DOWN-swipe commit should COMMIT. Only a ready in-place result or a task action
        /// awaiting armed-confirmation is committable; a DOWN swipe in any other state (still
        /// loading/streaming, no input, declined, failed) is IGNORED — the user waits, and only a
        /// horizontal discard swipe cancels the in-flight generation (so nothing is ever leaked).
        var isCommittable: Bool {
            switch self {
            case .ready, .reviewingAction: return true
            default: return false
            }
        }

        /// Value equality. `reviewingAction` compares by its review's discriminant + preview fields
        /// (the payload is opaque), which is all the UI / tests observe.
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loadingModel, .loadingModel), (.noInput, .noInput),
                 (.committed, .committed):
                return true
            case let (.streaming(a), .streaming(b)): return a == b
            case let (.ready(a), .ready(b)): return a == b
            case let (.declined(a), .declined(b)): return a == b
            case let (.failed(a), .failed(b)): return a == b
            case let (.reviewingAction(a), .reviewingAction(b)):
                return TaskReview.previewEqual(a, b)
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    private let modelManager: ModelManager
    private let selection: SelectionProviding
    private let dispatcher: TaskDispatching
    /// The fire-time context provider (front app name / URL). Injected so the executor doesn't reach
    /// into AppKit itself; the input text is filled in by acquisition.
    private let contextProvider: @MainActor () -> FireContext

    /// The command currently being executed (set by `fire`, read by `commit`).
    private(set) var activeCommand: AICommand?
    /// The streaming task, retained so `cancel()` / a new fire can stop it (horizontal discard swipe).
    private var generationTask: Task<Void, Never>?

    init(modelManager: ModelManager,
         selection: SelectionProviding,
         dispatcher: TaskDispatching,
         contextProvider: @escaping @MainActor () -> FireContext = { FireContext() }) {
        self.modelManager = modelManager
        self.selection = selection
        self.dispatcher = dispatcher
        self.contextProvider = contextProvider
    }

    // MARK: - Fire (acquire → resolve → stream)

    /// Start executing `command`: acquire its input, resolve the template, select + load the model,
    /// and stream the result into `state`. Returns immediately; progress is observed via `state`.
    /// Cancels any in-flight generation first (a new fire supersedes the old).
    func fire(_ command: AICommand) {
        cancel()
        activeCommand = command
        state = .loadingModel

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.run(command)
        }
    }

    private func run(_ command: AICommand) async {
        // 1) Acquire input per the command's source (with the selection→clipboard fallback).
        let inputText = await acquireInput(for: command.input)

        // An input-requiring command with nothing acquired surfaces "no input" and does NOT call the
        // model (spec). `.none` requires no input; `screenRegion` carries its input as image bytes.
        if requiresTextInput(command.input),
           (inputText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Whitespace-only counts as empty: never run the model on effectively-empty input.
            state = .noInput
            return
        }

        // 2) Build the fire context and resolve the prompt template.
        var context = contextProvider()
        context.inputText = inputText
        let prompt = PromptTemplate.resolve(command.promptTemplate, with: context)

        // 3) Optional image for a screen-region (vision) command.
        var image: Data?
        if command.input == .screenRegion {
            image = await selection.captureScreenRegion()
            if image == nil {
                state = .noInput
                return
            }
        }

        // 4) Select + load the model for the command's capabilities (capability-based routing).
        let runtime: LLMRuntime
        do {
            runtime = try await modelManager.runtime(requiring: command.requiredCapabilities)
        } catch {
            state = .failed(message: Self.message(for: error))
            return
        }

        if Task.isCancelled { return }

        // 5) Branch on the output's nature. A SIDE-EFFECTING output (`.runTask` / `.sendTo`) does NOT
        // stream text — it resolves a schema-targeted, validated, parsed ACTION via the dispatcher and
        // lands in `.reviewingAction` (armed-confirmation) / `.declined` / `.failed`, or — when the
        // command's `confirmBeforeRun` is OFF — commits the side effect directly (honoring the stored
        // value; design D6). An IN-PLACE output streams as before.
        if let kind = Self.taskKind(for: command.output) {
            await runTask(kind, command: command, resolvedPrompt: prompt, context: context)
            return
        }

        // In-place: stream generation into observable state (so the canvas renders live).
        let request = LLMRequest(prompt: prompt, image: image)
        state = .streaming(partial: "")
        var accumulated = ""
        do {
            for try await token in runtime.generate(request) {
                if Task.isCancelled { return }
                accumulated += token.text
                state = .streaming(partial: accumulated)
            }
            if Task.isCancelled { return }
            state = .ready(result: accumulated)
        } catch let error as RuntimeError {
            if case .cancelled = error { return }   // a discard is not a failure
            state = .failed(message: Self.message(for: error))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(message: Self.message(for: error))
        }
    }

    /// Prepare (and, when review is off, fire) a side-effecting task. Maps the dispatcher's review to
    /// state: `.declined` → `.declined`; `.unavailable` → `.failed`; `.action` → `.reviewingAction`
    /// when `confirmBeforeRun` is on, else `execute` it directly → `.committed`.
    private func runTask(_ kind: TaskKind, command: AICommand, resolvedPrompt: String,
                         context: FireContext) async {
        let source = TaskSource(appName: context.capturedAppName, url: context.url, timestamp: context.date)
        let review = await dispatcher.prepare(kind, resolvedPrompt: resolvedPrompt, source: source)
        if Task.isCancelled { return }

        switch review {
        case let .declined(reason):
            state = .declined(reason: reason)
        case let .unavailable(reason):
            state = .failed(message: reason)
        case .action:
            if command.confirmBeforeRun {
                // Armed-confirmation: the side effect fires on the NEXT commit (slice 5 renders fields).
                state = .reviewingAction(review)
            } else {
                // Review skipped (the user disabled it): commit the side effect now (no extra gate).
                do {
                    try await dispatcher.execute(review)
                    state = .committed
                } catch {
                    state = .failed(message: Self.message(for: error))
                }
            }
        }
    }

    /// The `TaskKind` a side-effecting output routes to (a `.sendTo` output maps to the `.sendTo` task
    /// kind), or nil for an in-place output.
    private static func taskKind(for output: OutputTarget) -> TaskKind? {
        switch output {
        case let .runTask(kind): return kind
        case let .sendTo(destination): return .sendTo(destination)
        case .replaceSelection, .pasteAtCursor, .previewOnly: return nil
        }
    }

    // MARK: - Commit (route the ready result)

    /// Commit per the current state. An IN-PLACE `.ready` result routes through `SelectionProviding`
    /// exactly as before. A `.reviewingAction` (armed-confirmation, reached only when the command's
    /// `confirmBeforeRun` is on) fires the reviewed side effect through `TaskDispatching.execute`. A
    /// side-effecting command with review OFF already committed in `run()`, so there's nothing here.
    /// No-op for any other state. Throws task errors so the caller can surface them.
    func commit() async throws {
        // Armed-confirmation commit: fire the reviewed side effect (design D6). On a throw (e.g. the
        // default-calendar path is denied), surface `.failed` with a human message AND rethrow so the
        // caller still sees the error — consistent with the review-OFF branch in `runTask`.
        if case let .reviewingAction(review) = state {
            do {
                try await dispatcher.execute(review)
                state = .committed
            } catch {
                state = .failed(message: Self.message(for: error))
                throw error
            }
            return
        }

        guard case let .ready(result) = state, let command = activeCommand else { return }

        switch command.output {
        case .replaceSelection:
            _ = await selection.replaceSelection(result)
            state = .committed
        case .pasteAtCursor:
            await selection.pasteAtCursor(result)
            state = .committed
        case .previewOnly:
            // Deliberately writes nothing into the app (spec: "Preview-only never writes").
            state = .committed
        case .runTask, .sendTo:
            // Side-effecting outputs never land in `.ready` (they go through `runTask` → review /
            // direct execute), so this is unreachable; kept exhaustive for safety.
            state = .committed
        }
    }

    /// Discard the current fire: cancel any in-flight generation and reset to idle. Writes nothing.
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        state = .idle
    }

    // MARK: - Input acquisition

    /// Acquire the input text for a source, applying the selection→clipboard fallback (spec: "Empty
    /// selection falls back to clipboard"). `screenRegion` / `none` carry no text here.
    private func acquireInput(for source: InputSource) async -> String? {
        switch source {
        case .selection:
            // A whitespace-only selection is treated as empty → fall back to the clipboard.
            if let sel = await selection.readSelectedText(),
               !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sel }
            return selection.readClipboardText()   // fallback when the selection is empty/blank
        case .clipboard:
            return selection.readClipboardText()
        case .screenRegion, .none:
            return nil
        }
    }

    /// Whether a source needs non-empty text before the model may run (`screenRegion` carries an
    /// image, not text; `none` needs nothing).
    private func requiresTextInput(_ source: InputSource) -> Bool {
        switch source {
        case .selection, .clipboard: return true
        case .screenRegion, .none: return false
        }
    }

    // MARK: - Messaging

    /// Map a runtime error to a short, user-facing message for the `.failed` state.
    private static func message(for error: Error) -> String {
        guard let runtime = error as? RuntimeError else {
            // Prefer a LocalizedError's human-facing description (e.g. TaskError) over the raw enum.
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        switch runtime {
        case let .unavailable(reason): return reason
        case .modelMissing: return "The model is not downloaded yet."
        case .integrityFailed: return "The model failed its integrity check; re-download required."
        case .cancelled: return "Cancelled."
        case let .couldNotProduceValid(attempts): return "Could not produce a valid result (\(attempts) attempts)."
        case let .decodeFailed(detail): return "Could not read the result: \(detail)"
        case let .unsupportedModality(modality): return "The model can't handle \(modality.rawValue) input."
        }
    }
}
