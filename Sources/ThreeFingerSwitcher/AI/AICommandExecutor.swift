import Foundation
import Combine
import os

/// Shares the `Selection` category with `SelectionService` so one Console.app filter
/// (`subsystem:ThreeFingerSwitcher category:Selection`) shows the whole chain: which channel the executor
/// resolved, and (from `SelectionService`) why the selection read did or didn't produce text.
private let aiInputLog = Logger(subsystem: "ThreeFingerSwitcher", category: "Selection")

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
        /// AI can't produce a result yet: the opt-in is off, or the model isn't downloaded/ready. The
        /// canvas shows an enable/download affordance + a model picker; nothing is generated. A
        /// horizontal discard dismisses, and any download started continues in the background
        /// (configuration-hub: fire-time availability resolves in the canvas, not by hiding items).
        case unavailable
        /// Committed and done (in-place written or task dispatched).
        case committed

        /// Whether a turn is actively being produced (`fix-evict-thrash-and-hot-path`): the
        /// quiescence input mirroring `NotchSessionEngine.isTurnInFlight` — automatic model
        /// eviction must never fire while the CANVAS executor is loading or streaming.
        /// `.reviewingAction` counts as foreground-active (mid-conversation), not turn-in-flight.
        var isTurnInFlight: Bool {
            switch self {
            case .loadingModel, .streaming: return true
            default: return false
            }
        }

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
                 (.unavailable, .unavailable), (.committed, .committed):
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
    /// The model's streamed REASONING for the in-flight command ("show the model's thinking"). The
    /// text-path streaming loop appends every `.thinking`-channel token here (live, so the canvas's
    /// collapsible Thinking section updates as it streams) — while ONLY `.response` tokens accumulate
    /// into `state`/commit. Reset at the start of every `fire(...)` and on `cancel()` so a re-run or
    /// discard never shows stale thinking. Empty when the runtime emits no thinking (today's default).
    @Published private(set) var thinking: String = ""
    /// The active runtime language of the command in flight (spec: runtime parameter). `nil` when the
    /// active command declares no language parameter — drives whether the canvas shows the dropdown
    /// and what it shows selected. Resolved on every `fire` from persistence → declared default.
    @Published private(set) var activeLanguage: String?
    /// Whether the canvas's scrollable content is scrolled to the TOP — written by the canvas view from
    /// its scroll position, read by the resolve gate so a fresh **down** swipe commits ONLY when there's
    /// nothing more to scroll up to (otherwise the down-swipe is a scroll, not an apply). Not `@Published`
    /// (it's a gate input the view writes, not state the view renders) so updating it never re-renders the
    /// canvas. Reset to `true` on every `fire` (fresh content starts at the top).
    var canvasAtTop = true

    private let modelManager: ModelManager
    private let selection: SelectionProviding
    private let dispatcher: TaskDispatching
    /// The fire-time context provider (front app name / URL). Injected so the executor doesn't reach
    /// into AppKit itself; the input text is filled in by acquisition.
    private let contextProvider: @MainActor () -> FireContext
    /// Per-command remembered runtime language (the next-run default). Injected as closures so the
    /// executor stays AppKit/AppSettings-free; the app wires these to `AppSettings`, tests pass theirs.
    private let loadLanguage: @MainActor (UUID) -> String?
    private let saveLanguage: @MainActor (UUID, String) -> Void
    /// Whether the model should reason (think) before answering — thinking is filtered from the
    /// result. Injected as a closure so the executor stays AppSettings-free; the app wires it to the
    /// `aiReasoningEnabled` pref, tests pass their own.
    private let reasoning: @MainActor () -> Bool

    /// The command currently being executed (set by `fire`, read by `commit`).
    private(set) var activeCommand: AICommand?
    /// The streaming task, retained so `cancel()` / a new fire can stop it (horizontal discard swipe).
    private var generationTask: Task<Void, Never>?
    /// For a `screenRegion` command, the capture outcome supplied at fire time by the region picker
    /// (the picker captures the designated rectangle BEFORE the canvas opens — the executor never
    /// captures the screen itself). Retained across a same-command language re-run (`setLanguage`) so the
    /// re-translate reuses the captured image. `nil` for non-vision commands.
    private var presuppliedCapture: ScreenCaptureOutcome?
    /// Whether the input RESOLVED at the last fire came from a selection (design D2). Remembered from
    /// `fire` → `commit` so an in-place commit REPLACES the selection when it was the source, and PASTES
    /// at the cursor otherwise. Reset on every fire before resolution.
    private var resolvedWasSelection = false
    /// Called on the main actor AFTER the fire has ACQUIRED its input (or resolved to `.unavailable`), so
    /// the canvas panel may take key focus for its controls WITHOUT stealing the selection read: the
    /// controller keeps the panel pass-through until this fires. The selection MUST be read while the
    /// captured front app still holds key focus (a `.nonactivatingPanel` that becomes key first makes the
    /// front app's AX focused element / ⌘C fallback come back empty → a wrong fall-through to the
    /// clipboard). Injected by the app; nil in tests.
    var onReadyForInteraction: (@MainActor () -> Void)?
    /// The last fire's acquired input, retained so a same-command language re-run (`setLanguage`) reuses
    /// the SAME source instead of re-reading the selection (which would fail once the canvas panel has
    /// taken key focus) — mirroring how `presuppliedCapture` is retained for a vision re-translate.
    private var retainedAcquisition: Acquisition?

    /// The outcome of acquiring a fire's input (before the model runs).
    private enum Acquisition {
        /// Input ready (text and/or image; both nil = a standalone prompt). `wasSelection` drives commit.
        case ok(text: String?, image: Data?, wasSelection: Bool)
        /// An input-requiring command had no live input channel.
        case noInput
        /// Acquisition failed with a human-readable message (e.g. a missing Screen-Recording grant).
        case failed(String)
    }

    init(modelManager: ModelManager,
         selection: SelectionProviding,
         dispatcher: TaskDispatching,
         contextProvider: @escaping @MainActor () -> FireContext = { FireContext() },
         loadLanguage: @escaping @MainActor (UUID) -> String? = { _ in nil },
         saveLanguage: @escaping @MainActor (UUID, String) -> Void = { _, _ in },
         reasoning: @escaping @MainActor () -> Bool = { false }) {
        self.modelManager = modelManager
        self.selection = selection
        self.dispatcher = dispatcher
        self.contextProvider = contextProvider
        self.loadLanguage = loadLanguage
        self.saveLanguage = saveLanguage
        self.reasoning = reasoning
    }

    /// The active language for `command`: the remembered per-command choice, falling back to the
    /// command's declared `.language` default. `nil` when the command declares no language parameter.
    func resolvedLanguage(for command: AICommand) -> String? {
        guard case let .languageChoice(def, _)? = command.runtimeParameter else { return nil }
        return loadLanguage(command.id) ?? def
    }

    // MARK: - Fire (acquire → resolve → stream)

    /// Start executing `command`: acquire its input, resolve the template, select + load the model,
    /// and stream the result into `state`. Returns immediately; progress is observed via `state`.
    /// Cancels any in-flight generation first (a new fire supersedes the old).
    ///
    /// `screenCapture` is the region picker's capture outcome for a `screenRegion` command (the picker
    /// captures the designated rectangle before this fire); `nil` for non-vision commands and for the
    /// no-image overload. The outcome (not raw bytes) is passed so the executor maps a permission gap →
    /// `.failed` and an unavailable capture → `.noInput` itself, keeping the error taxonomy in one place.
    func fire(_ command: AICommand, screenCapture: ScreenCaptureOutcome? = nil, reuseInput: Bool = false) {
        cancel()
        thinking = ""   // clear any previous run's reasoning before the new fire streams its own
        canvasAtTop = true   // fresh content starts at the top (so a first down-swipe can apply)
        presuppliedCapture = screenCapture
        if !reuseInput { retainedAcquisition = nil }   // a fresh fire re-reads; a language re-run reuses
        activeCommand = command
        // Resolve the active runtime language up front (persisted choice → declared default → nil), so
        // the canvas dropdown reflects it even while loading / in the `.unavailable` state.
        activeLanguage = resolvedLanguage(for: command)

        // Fire-time availability gate (configuration-hub): if AI can't produce a result yet — the
        // opt-in is off, or the model isn't downloaded/ready — open the canvas in the `.unavailable`
        // state (enable/download + model picker) instead of generating. The model is never invoked
        // here; the user enables/downloads from the canvas (the download continues in the background),
        // and a horizontal discard dismisses.
        guard modelManager.optedIn, Self.modelIsOnDisk(modelManager.state) else {
            state = .unavailable
            onReadyForInteraction?()   // the canvas needs key focus for Enable / Download / model-picker
            return
        }

        state = .loadingModel
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.run(command, reuseInput: reuseInput)
        }
    }

    /// Whether the model's weights are present (downloaded/loaded) so a fire can produce a result
    /// without a download. A download/verify still in flight — or not-downloaded / failed — is treated
    /// as unavailable (the canvas offers download and reflects progress).
    static func modelIsOnDisk(_ state: ModelLifecycleState) -> Bool {
        switch state {
        case .ready, .loading, .loaded: return true
        case .notDownloaded, .downloading, .verifying, .failed: return false
        }
    }

    private func run(_ command: AICommand, reuseInput: Bool) async {
        // 1) Acquire the input against the live environment (change `ai-action-context-resolution`) — or
        //    REUSE the retained acquisition on a same-command language re-run, so a re-translate never
        //    re-reads the selection after the canvas panel has taken key focus.
        let acquisition: Acquisition
        if reuseInput, let retained = retainedAcquisition {
            acquisition = retained
        } else {
            acquisition = await acquire(command)
            retainedAcquisition = acquisition
        }
        if Task.isCancelled { return }

        // The input has now been READ while the front app still held key focus. Signal the controller it
        // may make the canvas key-interactive — taking key focus BEFORE this point steals the read (the
        // front app's AX focused element / ⌘C fallback come back empty), which is the "recognizes the
        // selection then falls back to the clipboard" bug this ordering fixes.
        onReadyForInteraction?()

        let inputText: String?
        let image: Data?
        resolvedWasSelection = false
        switch acquisition {
        case let .failed(message):
            state = .failed(message: message)   // e.g. a missing Screen-Recording grant
            return
        case .noInput:
            state = .noInput                    // input-requiring command with no live channel
            return
        case let .ok(text, img, wasSelection):
            inputText = text
            image = img
            resolvedWasSelection = wasSelection   // drives the in-place commit (replace vs paste)
        }

        // 2) Build the fire context and resolve the prompt template (`{lang}` ⇐ the active language).
        var context = contextProvider()
        context.inputText = inputText
        let prompt = PromptTemplate.resolve(command.promptTemplate, with: context, activeLanguage: activeLanguage)

        // 3) Select + load the model for the RESOLVED input's capability — a vision model only when the
        // resolved channel is actually an image, else a text model (design D3: capability follows the
        // live input, not the authored superset).
        let runtime: LLMRuntime
        do {
            let caps: Set<Modality> = (image != nil) ? [.vision] : [.text]
            runtime = try await modelManager.runtime(requiring: caps)
        } catch {
            state = .failed(message: Self.message(for: error))
            return
        }

        if Task.isCancelled { return }

        // Resolve reasoning ONCE for this command: an explicit per-command override wins, else the
        // global default (the injected closure). The executor owns this resolution and threads the
        // result into both the text request and the task path.
        let useReasoning = command.resolvedReasoning(globalDefault: reasoning())

        // 4) Branch on the output's nature. A SIDE-EFFECTING output (`.runTask` / `.sendTo`) does NOT
        // stream text — it resolves a schema-targeted, validated, parsed ACTION via the dispatcher and
        // lands in `.reviewingAction` (armed-confirmation) / `.declined` / `.failed`, or — when the
        // command's `confirmBeforeRun` is OFF — commits the side effect directly (honoring the stored
        // value; design D6). An IN-PLACE output streams as before.
        if let kind = Self.taskKind(for: command) {
            await runTask(kind, command: command, resolvedPrompt: prompt, context: context,
                          reasoning: useReasoning)
            return
        }

        // In-place: stream generation into observable state (so the canvas renders live). Tokens are
        // split by channel: `.thinking` chunks accumulate into the observable `thinking` (the canvas's
        // collapsible reasoning section) and NEVER reach the committed result; only `.response` chunks
        // accumulate into `accumulated` → `state` → commit ("show the thinking, commit the response").
        let request = LLMRequest(prompt: prompt, image: image, reasoning: useReasoning)
        state = .streaming(partial: "")
        var accumulated = ""
        do {
            for try await token in runtime.generate(request) {
                if Task.isCancelled { return }
                switch token.channel {
                case .thinking:
                    thinking += token.text   // live into the canvas's Thinking section; never committed
                case .response:
                    accumulated += token.text
                    state = .streaming(partial: accumulated)
                }
            }
            if Task.isCancelled { return }
            state = .ready(result: accumulated)   // RESPONSE ONLY — thinking is never part of the result
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
                         context: FireContext, reasoning: Bool) async {
        let source = TaskSource(appName: context.capturedAppName, url: context.url, timestamp: context.date)
        let review = await dispatcher.prepare(kind, resolvedPrompt: resolvedPrompt, source: source,
                                              reasoning: reasoning)
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

    /// The `TaskKind` a command's side-effecting output routes to (a `.sendTo` output maps to the
    /// `.sendTo` task kind), or nil for an in-place command. Reads the command's single side-effecting
    /// output capability (`sideEffect`).
    private static func taskKind(for command: AICommand) -> TaskKind? {
        switch command.sideEffect {
        case let .runTask(kind): return kind
        case let .sendTo(destination): return .sendTo(destination)
        default: return nil
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

        // Resolve the in-place commit from the input channel that won at fire + the enabled outputs
        // (design D2): a selection source replaces; a clipboard/image source pastes; preview-only writes
        // nothing. Side-effecting outputs never land in `.ready` (they route through `runTask`).
        switch AICommand.inPlaceCommitPlan(resolvedWasSelection: resolvedWasSelection, outputs: command.outputs) {
        case .replaceSelection:
            // Honesty (spec D5): a write that didn't actually land is a failure, not a "Done".
            if await selection.replaceSelection(result) {
                state = .committed
            } else {
                state = .failed(message: "Couldn't apply the result to the active app.")
            }
        case .pasteAtCursor:
            if await selection.pasteAtCursor(result) {
                state = .committed
            } else {
                state = .failed(message: "Couldn't paste the result into the active app.")
            }
        case .preview:
            // Deliberately writes nothing into the app (spec: "Preview-only never writes").
            state = .committed
        }
    }

    /// Discard the current fire: cancel any in-flight generation and reset to idle. Writes nothing.
    /// Also clears any streamed reasoning so a discard never leaves stale thinking behind.
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        thinking = ""
        state = .idle
    }

    // MARK: - Runtime parameter (in-canvas language re-run)

    /// Re-run the active command against a newly chosen runtime `language` (launcher-overlay: the
    /// in-canvas dropdown re-translates in place). Persists the choice per command — so the next run
    /// defaults to it — then re-fires, which cancels the in-flight generation (cancellation is not a
    /// failure) and streams the new language into the same canvas. A no-op when the active command
    /// declares no language parameter, or when the language is unchanged (avoids a redundant re-run).
    func setLanguage(_ language: String) {
        guard let command = activeCommand,
              case .languageChoice? = command.runtimeParameter,
              language != activeLanguage else { return }
        saveLanguage(command.id, language)
        // Re-read the just-persisted language via `resolvedLanguage`; re-pass the picker's capture so a
        // vision re-translate (e.g. "Translate Image Text") reuses the captured image. `reuseInput: true`
        // reuses the ALREADY-ACQUIRED source text/image rather than re-reading the selection — which would
        // now fail, since the canvas panel took key focus after the first fire.
        fire(command, screenCapture: presuppliedCapture, reuseInput: true)
    }
    // MARK: - Input acquisition (ambient cascade)

    /// Acquire a fire's input from the live environment. A `screenRegion` command uses the pre-supplied
    /// picker capture (region-first; a permission gap → `.failed`, an unavailable/cancelled capture →
    /// `.noInput`); everything else walks the ambient cascade `selection ▸ clipboard-text ▸ clipboard-image`
    /// and remembers whether the selection won (drives the in-place commit).
    private func acquire(_ command: AICommand) async -> Acquisition {
        if command.inputs.contains(.screenRegion) {
            switch presuppliedCapture {
            case let .captured(data):
                return .ok(text: nil, image: data, wasSelection: false)
            case .permissionDenied:
                return .failed("Screen Recording permission is required for this command. "
                    + "Enable it in System Settings ▸ Privacy & Security ▸ Screen Recording.")
            case .unavailable, .none:
                return .noInput
            }
        }
        switch await resolveAmbientInput(for: command) {
        case let .selection(text):      return .ok(text: text, image: nil, wasSelection: true)
        case let .clipboardText(text):  return .ok(text: text, image: nil, wasSelection: false)
        case let .clipboardImage(data): return .ok(text: nil, image: data, wasSelection: false)
        case .none:
            // A command that requires input but has no live channel surfaces "no input" (no model run); a
            // standalone command (empty `inputs`) proceeds with no input (its template stands alone).
            return command.needsInput ? .noInput : .ok(text: nil, image: nil, wasSelection: false)
        }
    }

    /// The input channel resolved from the live environment (change `ai-action-context-resolution`).
    /// `.none` = no enabled channel was live.
    private enum ResolvedInput {
        case selection(String)
        case clipboardText(String)
        case clipboardImage(Data)
        case none
    }

    /// Resolve the active ambient input by walking the command's ENABLED channels in priority order and
    /// returning the first that is live (design D1): a non-empty selection ▸ non-empty clipboard text ▸ a
    /// decodable clipboard image. Text beats image so a plain transform stays a cheap text run; the image
    /// channel engages only when there is no usable text anywhere. `screenRegion` is handled separately
    /// (region-first), never here. Whitespace-only reads count as empty (the read primitives normalize).
    private func resolveAmbientInput(for command: AICommand) async -> ResolvedInput {
        aiInputLog.notice("resolveAmbientInput: enabled = [\(command.inputs.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)]")
        if command.inputs.contains(.selection),
           let sel = await selection.readSelectedText(),
           !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiInputLog.notice("resolveAmbientInput → SELECTION (\(sel.count) chars)")
            return .selection(sel)
        }
        if command.inputs.contains(.clipboard),
           let clip = selection.readClipboardText(),
           !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiInputLog.notice("resolveAmbientInput → CLIPBOARD TEXT (\(clip.count) chars) — selection empty/disabled, fell back")
            return .clipboardText(clip)
        }
        if command.inputs.contains(.clipboardImage),
           let img = selection.readClipboardImage() {
            aiInputLog.notice("resolveAmbientInput → CLIPBOARD IMAGE (\(img.count) bytes)")
            return .clipboardImage(img)
        }
        aiInputLog.notice("resolveAmbientInput → NONE (no live channel)")
        return .none
    }

    // MARK: - Messaging

    /// Map any error to a short, user-facing message for the `.failed` state, via the single central
    /// translator (`AIError`). This guarantees the canvas shows the SAME clean headline the Settings
    /// row shows for the same error, and that a non-`LocalizedError` can never dump raw text into the
    /// canvas (the old `?? "\(error)"` fallback is gone — `AIError` returns a safe generic instead).
    private static func message(for error: Error) -> String {
        AIError.message(for: error).headline
    }
}
