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
        /// AI can't produce a result yet: the opt-in is off, or the model isn't downloaded/ready. The
        /// canvas shows an enable/download affordance + a model picker; nothing is generated. A
        /// horizontal discard dismisses, and any download started continues in the background
        /// (configuration-hub: fire-time availability resolves in the canvas, not by hiding items).
        case unavailable
        /// Committed and done (in-place written or task dispatched).
        case committed
        /// An assistant turn is streaming WITHIN an open conversation thread (design D4) — distinct from
        /// the one-shot `.streaming`, so the preset path's commit semantics stay untouched. `partial` is
        /// the response-channel accumulation for the in-flight turn (the canvas slice renders it).
        case conversing(partial: String)
        /// An open conversation thread is idle, awaiting the next user turn (Enter = send, from the
        /// canvas). (`.awaitingApproval`/`.parked` are owned by `ai-tool-routing`/`ai-conversational-canvas`
        /// and added there additively — not here.)
        case awaitingTurn
        /// The conversational canvas is open SHOWING THE SEED and WAITING — turn 1 is built and shown but
        /// the model has NOT run yet (design D1, this slice owns this case). The float-up placeholder sits
        /// over the seed; Enter / a commit-bound excursion sends turn 1 (a bare seed sends the
        /// `BareSeedDefault` question). Distinct from `.awaitingTurn` (an assistant turn already completed):
        /// only `.awaitingSeed` triggers the bare-seed default, and it renders the placeholder-over-seed,
        /// not a full thread. NOT committable (DOWN does nothing until there is an assistant turn).
        case awaitingSeed
        /// The conversation was PARKED to the notch home zone (design D7, this slice): the live
        /// `AgentConversation` was handed to `ai-parked-sessions`; the canvas recedes + tears down. A
        /// terminal canvas state (the session lives on in the parked store, not here).
        case parked
        /// The bounded route loop reached a `.confirm`/`.dangerous` tool step and is AWAITING the user's
        /// decision (design D7, `ai-tool-routing` gate driven here): the canvas renders the carried
        /// `TaskReview` as a review card, and the canonical compass resolves it — DOWN = approve, RIGHT =
        /// skip (the same mnemonic as commit / discard). NOT `isCommittable`: DOWN-when-`.awaitingApproval`
        /// is handled BEFORE the commit gate at the consumer seam (it approves the step, it does not extract
        /// an answer), so the existing at-top commit path stays untouched.
        case awaitingApproval(TaskReview)

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

        /// Whether the route loop is paused awaiting a tool-step decision (design D7). The consumer seam
        /// reads this BEFORE the at-top commit gate: DOWN approves the step / RIGHT skips it, instead of
        /// extracting an assistant answer. Kept distinct from `isCommittable` so the in-place commit path
        /// (`extractLatest`) is never reached while a step is pending.
        var isAwaitingApproval: Bool {
            if case .awaitingApproval = self { return true }
            return false
        }

        /// Value equality. `reviewingAction` compares by its review's discriminant + preview fields
        /// (the payload is opaque), which is all the UI / tests observe.
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loadingModel, .loadingModel), (.noInput, .noInput),
                 (.unavailable, .unavailable), (.committed, .committed), (.awaitingTurn, .awaitingTurn),
                 (.awaitingSeed, .awaitingSeed), (.parked, .parked):
                return true
            case let (.streaming(a), .streaming(b)): return a == b
            case let (.conversing(a), .conversing(b)): return a == b
            case let (.ready(a), .ready(b)): return a == b
            case let (.declined(a), .declined(b)): return a == b
            case let (.failed(a), .failed(b)): return a == b
            case let (.reviewingAction(a), .reviewingAction(b)):
                return TaskReview.previewEqual(a, b)
            case let (.awaitingApproval(a), .awaitingApproval(b)):
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
    /// Whether the canvas's scrollable thread is scrolled to its BOTTOM — the companion to `canvasAtTop`
    /// (design D4), written by the canvas view from its scroll position, read by the overscroll-park gate at
    /// the consumer seam (`OverscrollPark.shouldPark`). Not `@Published` (a gate input the view writes, not
    /// rendered state) so updating it never re-renders the canvas. Reset to `true` on every open (a fresh,
    /// short thread sits at the bottom — so an immediate overscroll-up can park, symmetric to the at-top
    /// commit guard reset).
    var canvasAtBottom = true

    /// The seed's nature for the active conversation (design D6) — captured when the conversational canvas
    /// opens, so a bare-seed `send()` can pick the right `BareSeedDefault` question. `nil` for the one-shot
    /// path / no open conversation.
    private(set) var seedKind: SeedKind?
    /// The active conversation's output target (design D5) — captured at open so `extractLatest()` knows
    /// where the affirmed answer goes (`replaceSelection`/`pasteAtCursor`/`previewOnly`). `nil` for the
    /// one-shot path / no open conversation.
    private(set) var conversationOutput: OutputTarget?
    /// The raw seed text + image, captured at open, so a bare-seed `send()` (empty composer) can fold the
    /// `BareSeedDefault` question with the seed for turn 1 (the model is never run on an empty turn).
    private var pendingSeedText: String = ""
    private var pendingSeedImage: Data?
    /// Hand a parked conversation off to `ai-parked-sessions` (design D7). Injected as a closure so the
    /// executor stays free of the parked store/scheduler concretes; the app wires the real scheduler, tests
    /// pass their own capture. Called by `parkHandoff()` BEFORE the canvas recedes; does NOT cancel the
    /// in-flight turn (the scheduler keeps advancing it in the background).
    var onPark: (@MainActor (AgentConversation) -> Void)?

    /// Report that the active conversation's foreground op FINISHED (design D1 / Bug 3 terminal detection):
    /// a committed conversational result (`extractLatest`) or a committed one-shot side effect is a terminal
    /// outcome, so `ai-parked-sessions` marks any matching parked row `.completed` → auto-dismissed forever.
    /// Injected as a closure so the executor stays free of the parked store/scheduler concretes (mirrors
    /// `onPark`); the app wires the real controller, tests capture it. A no-op when no conversation is open.
    var onTaskComplete: (@MainActor (AgentSessionID) -> Void)?

    /// The ordered tool steps the route loop has run for the active conversation (design D7 / task 4.2) —
    /// the canvas renders a compact list of `ToolStepResult.summary`. `@Published` so the thread updates
    /// live as steps land. Reset whenever a fresh conversation opens / a one-shot fire runs.
    @Published private(set) var toolSteps: [ToolStepResult] = []

    /// The composer's PENDING attachments for the NEXT user turn (design D2 / Bug 6): images the user has
    /// staged (a clipboard image, a captured screenshot) that the next `send(_:)` folds into the appended
    /// user `AgentMessage.images`. `@Published` so the composer renders the attachment chips live. Cleared
    /// the instant a turn is sent (the images move onto the message) and on discard/park/restore.
    @Published private(set) var pendingAttachments = PendingAttachments()

    /// The transient set of images staged on the composer before the next send (design D2). Pure value —
    /// the executor owns it; the composer UI (stage 3) renders/edits it via the executor's attach/remove
    /// seams. `text` is reserved for a future staged-text affordance; today only `images` is populated.
    struct PendingAttachments: Equatable {
        /// Staged images for the next turn (each PNG); folded into the next user message's `images`.
        var images: [Data] = []
        /// Whether anything is staged (drives the composer's "has attachments" affordance).
        var isEmpty: Bool { images.isEmpty }
    }

    /// The approval gate the route loop awaits at a `.confirm`/`.dangerous` step (task 2.8). Created lazily
    /// per pause; the canvas compass resolves it through `approve()` / `skip()`. Held so a discard can
    /// `.cancel` any pending pause (the loop ends cleanly, never deadlocked).
    private var approvalGate: CanvasApprovalGate?

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
    /// The INJECTED context-token budget for compaction (integration fix C3): the executor depends on
    /// this protocol, NEVER on the concrete `agentContextTokens` slider, so this slice builds before
    /// `ai-batched-runtime-and-context`. The app wires the real provider; tests pass a fixed-budget stub.
    private let budgetProvider: ContextBudgetProviding

    /// The command currently being executed (set by `fire`, read by `commit`).
    private(set) var activeCommand: AICommand?
    /// The in-memory conversation thread for the active session (design D4) — `nil` until
    /// `startConversation` opens one, cleared when a one-shot `fire` runs. Durable persistence is owned by
    /// `ai-parked-sessions`; this slice holds it for the session's life in memory only. `private(set)` so
    /// the canvas/tests observe it without mutating it directly.
    private(set) var conversation: AgentConversation?
    /// Per-session reasoning + generation parameters, captured when the conversation opens and applied to
    /// every turn (the conversation has no per-fire `AICommand`).
    private var sessionReasoning = false
    private var sessionParameters: GenerationParameters = .default
    /// The streaming task, retained so `cancel()` / a new fire can stop it (horizontal discard swipe).
    private var generationTask: Task<Void, Never>?
    /// For a `screenRegion` command, the capture outcome supplied at fire time by the region picker
    /// (the picker captures the designated rectangle BEFORE the canvas opens — the executor never
    /// captures the screen itself). Retained across a same-command language re-run (`setLanguage`) so the
    /// re-translate reuses the captured image. `nil` for non-vision commands.
    private var presuppliedCapture: ScreenCaptureOutcome?

    init(modelManager: ModelManager,
         selection: SelectionProviding,
         dispatcher: TaskDispatching,
         contextProvider: @escaping @MainActor () -> FireContext = { FireContext() },
         loadLanguage: @escaping @MainActor (UUID) -> String? = { _ in nil },
         saveLanguage: @escaping @MainActor (UUID, String) -> Void = { _, _ in },
         reasoning: @escaping @MainActor () -> Bool = { false },
         budgetProvider: ContextBudgetProviding = DefaultContextBudget()) {
        self.modelManager = modelManager
        self.selection = selection
        self.dispatcher = dispatcher
        self.contextProvider = contextProvider
        self.loadLanguage = loadLanguage
        self.saveLanguage = saveLanguage
        self.reasoning = reasoning
        self.budgetProvider = budgetProvider
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
    func fire(_ command: AICommand, screenCapture: ScreenCaptureOutcome? = nil) {
        cancel()
        conversation = nil   // a one-shot preset fire is not part of a conversation thread
        toolSteps = []       // no route-loop steps for a one-shot fire
        seedKind = nil; conversationOutput = nil   // one-shot path is not a conversational session
        thinking = ""   // clear any previous run's reasoning before the new fire streams its own
        canvasAtTop = true   // fresh content starts at the top (so a first down-swipe can apply)
        canvasAtBottom = true
        clearPendingAttachments()   // a one-shot fire is not a conversation; no staged composer attachments
        presuppliedCapture = screenCapture
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
            return
        }

        state = .loadingModel
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.run(command)
        }
    }

    /// Fire `command` as a CONVERSATIONAL canvas (design D1/D5, task 6.1 FIRE path) — the V2 default front
    /// end. Unlike `fire(_:)` (which auto-streams a one-shot preset), this acquires the seed exactly as the
    /// one-shot path does, then routes through `openConversationCanvas`:
    ///
    /// - A **generic "Ask…"** command (an `{input}`-only / empty template with `previewOnly` output) opens
    ///   the canvas SHOWING THE SEED and WAITING (`autoSendTurn1 == false`) — the model is not run until the
    ///   user sends.
    /// - A **preset** (Fix Grammar / Translate / a side-effecting task — any command with a real prompt
    ///   instruction) opens the SAME canvas with turn 1 pre-filled (the resolved template, the canned
    ///   instruction folded with the seed) and AUTO-SENDS it (`autoSendTurn1 == true`) — identical to today's
    ///   auto-fire feel, now as turn 1 of a thread.
    ///
    /// Acquisition + the `.unavailable`/`.noInput`/permission mapping match `fire(_:)` exactly; the seed text
    /// (and any vision image) become turn 1. Returns immediately; progress is observed via `state`.
    func fireConversational(_ command: AICommand, screenCapture: ScreenCaptureOutcome? = nil) {
        cancel()
        presuppliedCapture = screenCapture
        activeCommand = command
        activeLanguage = resolvedLanguage(for: command)

        // Same fire-time availability gate as the one-shot path: no model → `.unavailable`, never silence.
        guard modelManager.optedIn, Self.modelIsOnDisk(modelManager.state) else {
            state = .unavailable
            return
        }

        let useReasoning = command.resolvedReasoning(globalDefault: reasoning())
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.openConversational(command, reasoning: useReasoning)
        }
    }

    /// Acquire the seed for a conversational fire (text and/or image), mapping a missing seed / permission
    /// gap exactly as the one-shot `run(_:)` does, then open the canvas via `openConversationCanvas`.
    private func openConversational(_ command: AICommand, reasoning useReasoning: Bool) async {
        // 1) Acquire input text per the source (with the selection→clipboard fallback).
        let inputText = await acquireInput(for: command.input)
        if requiresTextInput(command.input),
           (inputText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .noInput
            return
        }

        // 2) Acquire the optional vision image (same outcome mapping as `run`).
        var image: Data?
        if command.input == .screenRegion {
            switch presuppliedCapture {
            case let .captured(data): image = data
            case .permissionDenied:
                state = .failed(message: "Screen Recording permission is required for this command. "
                    + "Enable it in System Settings ▸ Privacy & Security ▸ Screen Recording.")
                return
            case .unavailable, .none:
                state = .noInput
                return
            }
        } else if command.input == .clipboardImage {
            guard let data = selection.readClipboardImage() else { state = .noInput; return }
            image = data
        }

        if Task.isCancelled { return }

        let seedText = inputText ?? ""
        let kind = SeedKind.from(command.input)
        let parameters = GenerationParameters.default
        if Self.isConversationalAsk(command) {
            // Generic Ask: open showing the seed and WAIT (no auto-send).
            openConversationCanvas(seedText: seedText, image: image, seedKind: kind,
                                   output: command.output, autoSendTurn1: false,
                                   parameters: parameters, reasoning: useReasoning)
        } else {
            // Preset: turn 1 is the resolved template (the canned instruction folded with the seed) and it
            // auto-sends — same canvas, same machine (design D5).
            var context = contextProvider()
            context.inputText = inputText
            let turn1 = PromptTemplate.resolve(command.promptTemplate, with: context, activeLanguage: activeLanguage)
            openConversationCanvas(seedText: seedText, image: image, seedKind: kind,
                                   output: command.output, turn1Prompt: turn1, autoSendTurn1: true,
                                   parameters: parameters, reasoning: useReasoning)
        }
    }

    /// Whether a command is the generic conversational "Ask…" (open-and-wait, no auto-send): an empty or
    /// `{input}`-only prompt template paired with `previewOnly` output. Every other command (a real
    /// instruction template, or any non-preview output) is a preset that auto-sends turn 1 (design D5).
    static func isConversationalAsk(_ command: AICommand) -> Bool {
        guard command.output == .previewOnly else { return false }
        let template = command.promptTemplate
            .replacingOccurrences(of: "{input}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return template.isEmpty
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

    private func run(_ command: AICommand) async {
        // 1) Acquire input per the command's source (with the selection→clipboard fallback).
        let inputText = await acquireInput(for: command.input)

        // An input-requiring command with nothing acquired surfaces "no input" and does NOT call the
        // model (spec). `.none` requires no input; the image sources (`screenRegion`, `clipboardImage`)
        // carry their input as image bytes, acquired in step 3.
        if requiresTextInput(command.input),
           (inputText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Whitespace-only counts as empty: never run the model on effectively-empty input.
            state = .noInput
            return
        }

        // 2) Build the fire context and resolve the prompt template (`{lang}` ⇐ the active language).
        var context = contextProvider()
        context.inputText = inputText
        let prompt = PromptTemplate.resolve(command.promptTemplate, with: context, activeLanguage: activeLanguage)

        // 3) Optional image for a vision command. A `screenRegion` command's image was captured by the
        // region picker BEFORE this fire and handed in as `presuppliedCapture`; the executor maps that
        // outcome (a missing Screen-Recording grant → a clear `.failed` naming the permission, not
        // silently "no input"). A `clipboardImage` reads the live pasteboard image here (no permission,
        // no synthesis): no image is plain "no input". An image source never falls back to text.
        var image: Data?
        if command.input == .screenRegion {
            switch presuppliedCapture {
            case let .captured(data):
                image = data
            case .permissionDenied:
                state = .failed(message: "Screen Recording permission is required for this command. "
                    + "Enable it in System Settings ▸ Privacy & Security ▸ Screen Recording.")
                return
            case .unavailable, .none:
                state = .noInput   // cancelled / no capture supplied → "no input" (no model run)
                return
            }
        } else if command.input == .clipboardImage {
            guard let data = selection.readClipboardImage() else {
                state = .noInput   // no image on the clipboard → "no input"; the model is not invoked
                return
            }
            image = data
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

        // Resolve reasoning ONCE for this command: an explicit per-command override wins, else the
        // global default (the injected closure). The executor owns this resolution and threads the
        // result into both the text request and the task path.
        let useReasoning = command.resolvedReasoning(globalDefault: reasoning())

        // 5) Branch on the output's nature. A SIDE-EFFECTING output (`.runTask` / `.sendTo`) does NOT
        // stream text — it resolves a schema-targeted, validated, parsed ACTION via the dispatcher and
        // lands in `.reviewingAction` (armed-confirmation) / `.declined` / `.failed`, or — when the
        // command's `confirmBeforeRun` is OFF — commits the side effect directly (honoring the stored
        // value; design D6). An IN-PLACE output streams as before.
        if let kind = Self.taskKind(for: command.output) {
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
    /// Also clears any streamed reasoning so a discard never leaves stale thinking behind.
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        // Resolve any pending tool-step pause to `.cancel` so the route loop ends cleanly (never deadlocked).
        approvalGate?.resolve(.cancel)
        approvalGate = nil
        thinking = ""
        toolSteps = []
        seedKind = nil
        conversationOutput = nil
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
        // vision re-translate (e.g. "Translate Image Text") reuses the captured image, not a blank one.
        fire(command, screenCapture: presuppliedCapture)
    }

    // MARK: - Conversational canvas (Wave 4: seed → wait → send → affirm/park)

    /// Open the CONVERSATIONAL canvas from a seed (design D1) — the front-end entry the canvas slice calls.
    /// Unlike `startConversation` (which auto-streams turn 1), this:
    ///
    /// - **Conversational open** (`autoSendTurn1 == false`, the "Ask…" default): builds turn 1 from the
    ///   seed, opens the `AgentConversation`, and lands in **`.awaitingSeed`** — it SHOWS THE SEED and WAITS;
    ///   the model is NOT invoked until the user sends (Enter / a commit excursion). The seed (`seedKind` +
    ///   `output`) is captured so a bare-seed `send()` folds the right `BareSeedDefault` question and DOWN
    ///   later routes the latest answer to the right output target.
    /// - **Preset open** (`autoSendTurn1 == true`, Fix Grammar / Translate): the SAME machine, but turn 1 is
    ///   pre-filled (`turn1Prompt`, the canned instruction already folded with the seed by the caller) and
    ///   it AUTO-SENDS once — identical to today's auto-fire feel, now as turn 1 of a thread. (D5: a preset
    ///   is a pre-filled, auto-sent turn 1 — one entry with a parameter, not a parallel path.)
    ///
    /// The availability + empty-seed gates match the one-shot path exactly: no model → `.unavailable`; an
    /// empty-and-imageless seed → `.noInput`, no conversation opened, no model call.
    func openConversationCanvas(seedText: String,
                                image: Data? = nil,
                                seedKind: SeedKind,
                                output: OutputTarget,
                                turn1Prompt: String? = nil,
                                autoSendTurn1: Bool,
                                parameters: GenerationParameters = .default,
                                reasoning: Bool = false) {
        generationTask?.cancel()
        generationTask = nil
        approvalGate?.resolve(.cancel); approvalGate = nil
        thinking = ""
        toolSteps = []
        canvasAtTop = true
        canvasAtBottom = true
        clearPendingAttachments()   // a fresh conversational open starts with an empty composer (design D2)

        // Same fire-time availability gate as the one-shot path: no model → `.unavailable`, never silence.
        guard modelManager.optedIn, Self.modelIsOnDisk(modelManager.state) else {
            conversation = nil; self.seedKind = nil; conversationOutput = nil
            state = .unavailable
            return
        }
        // Empty-and-imageless seed → no conversation, no model call (preserves `.noInput`).
        if seedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, image == nil {
            conversation = nil; self.seedKind = nil; conversationOutput = nil
            state = .noInput
            return
        }

        // Capture the session shape this slice owns.
        self.seedKind = seedKind
        conversationOutput = output
        pendingSeedText = seedText
        pendingSeedImage = image
        sessionReasoning = reasoning
        sessionParameters = parameters

        if autoSendTurn1 {
            // Preset: turn 1 is the pre-filled prompt (already folded with the seed by the caller) and it
            // streams immediately — reuse the runtime slice's auto-streaming open verbatim.
            startConversation(seedText: turn1Prompt ?? seedText, image: image,
                              parameters: parameters, reasoning: reasoning)
            // Re-capture (startConversation cleared nothing of ours, but be explicit for the session shape).
            self.seedKind = seedKind
            conversationOutput = output
        } else {
            // Conversational: open the thread showing the seed and WAIT. The model is NOT invoked.
            let now = Date()
            let seed = AgentMessage(role: .user, text: seedText, image: image, createdAt: now)
            conversation = AgentConversation(title: Self.conversationTitle(from: seedText),
                                             messages: [seed], createdAt: now, updatedAt: now)
            state = .awaitingSeed
        }
    }

    /// Send the next turn from the conversational canvas (Enter = send, or a commit excursion while
    /// `.awaitingSeed`). Two cases (design D2/D6):
    ///
    /// - **From `.awaitingSeed`** (turn 1 not yet run): if `text` is non-empty it BECOMES turn 1's question,
    ///   folded with the already-shown seed (`{question}\n\n{seed}` for text; the question alone for a
    ///   vision seed whose image already rides turn 1). An EMPTY composer sends the `BareSeedDefault`
    ///   question for the seed kind — a bare seed is always a valid turn 1, never an empty model call. The
    ///   seed message text is REWRITTEN to the folded turn-1 content, then the assistant turn streams.
    /// - **From `.awaitingTurn`** (an assistant turn completed): a pure-text follow-up (one-source — never
    ///   re-acquires a selection/clipboard/region or attaches an image), delegated to `continueConversation`.
    ///
    /// `images` are the composer's staged attachments for this turn (design D2 / Bug 6): on a follow-up
    /// they ride the appended user message; on a bare seed (`.awaitingSeed`) they AUGMENT turn 1's seed
    /// message (`messages[0].images`). Defaults to `[]` so existing text-only callers/tests are unchanged.
    /// The pending-attachments model is cleared once the images are folded onto the message.
    ///
    /// A no-op when no conversation is open, or from `.awaitingTurn` with empty text AND no images.
    func send(_ text: String, images: [Data] = []) {
        guard conversation != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The turn's images = the explicitly passed ones, else whatever the composer staged.
        let turnImages = images.isEmpty ? pendingAttachments.images : images

        if case .awaitingSeed = state {
            // Build turn 1's question: the typed question, or the bare-seed default for an empty composer.
            let question = trimmed.isEmpty
                ? BareSeedDefault.question(for: seedKind ?? .text)
                : text
            // Fold the question with the seed. A vision seed already carries its image on turn 1, so for an
            // image seed with no seed text we send the question alone; otherwise prefix the question.
            let folded: String
            let seedBody = pendingSeedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if seedBody.isEmpty {
                folded = question
            } else {
                folded = "\(question)\n\n\(pendingSeedText)"
            }
            // Rewrite turn 1's user message to the folded content (the seed message IS turn 1), and
            // AUGMENT its images with any freshly-attached ones (design D2: a seed image + a staged image
            // ride the same turn). The seed's own image is already on `messages[0].images`.
            if conversation?.messages.first?.role == .user {
                conversation?.messages[0].text = folded
                if !turnImages.isEmpty {
                    conversation?.messages[0].images.append(contentsOf: turnImages)
                }
            }
            conversation?.updatedAt = Date()
            clearPendingAttachments()

            generationTask?.cancel()
            state = .loadingModel
            generationTask = Task { [weak self] in
                guard let self else { return }
                await self.runTurn()
            }
            return
        }

        // Otherwise it is a follow-up turn (the typed text + any staged/passed images).
        continueConversation(text, images: turnImages)
    }

    /// Affirm the LATEST assistant turn (design D5/D7) — the conversational generalization of the one-shot
    /// `commit()`. Reads the last assistant message's `text` and routes it through the conversation's
    /// captured output target via `SelectionProviding`, honoring the honesty rule (a write that did not land
    /// is `.failed`, never a false "Done"). `previewOnly` writes nothing → `.committed`. A no-op when there
    /// is no assistant turn yet or no open conversation. Throws so the caller can surface a write error.
    func extractLatest() async {
        guard let conversation else { return }
        guard let latest = conversation.messages.last(where: { $0.role == .assistant })?.text else { return }
        let output = conversationOutput ?? .previewOnly
        switch output {
        case .replaceSelection:
            if await selection.replaceSelection(latest) {
                markCommitted(conversation.id)
            } else {
                state = .failed(message: "Couldn't apply the result to the active app.")
            }
        case .pasteAtCursor:
            if await selection.pasteAtCursor(latest) {
                markCommitted(conversation.id)
            } else {
                state = .failed(message: "Couldn't paste the result into the active app.")
            }
        case .previewOnly:
            markCommitted(conversation.id)   // deliberately writes nothing into the app
        case .runTask, .sendTo:
            // A side-effecting conversational command resolves through the route loop's approval, not an
            // in-place extract; reaching here means there is nothing to write. Kept exhaustive.
            markCommitted(conversation.id)
        }
    }

    /// Transition to `.committed` AND report the terminal outcome (design D1 / Bug 3): a committed
    /// conversational result is a finished task, so any matching parked row is marked `.completed` →
    /// auto-dismissed forever. Only the conversational path reports (it owns a durable session id).
    private func markCommitted(_ id: AgentSessionID) {
        state = .committed
        onTaskComplete?(id)
    }

    /// Park the open conversation to the notch home zone (design D7): hand the live `AgentConversation` to
    /// `ai-parked-sessions` (via the injected `onPark` seam) and transition `.parked`. It does NOT cancel
    /// the in-flight turn — the scheduler keeps advancing it in the background (a discard, by contrast,
    /// cancels). A no-op when no conversation is open. The canvas recedes + tears down after this returns.
    func parkHandoff() {
        guard let conversation else { return }
        onPark?(conversation)
        clearPendingAttachments()   // staged-but-unsent attachments don't follow a parked session (design D2)
        state = .parked
    }

    /// Re-bind a PARKED conversation handed back by the parked-sessions rail (design D7 / task 6.2): the
    /// canvas re-opens to render the restored thread, idling in `.awaitingTurn` (or `.awaitingApproval` if a
    /// step escalated — not modeled by the in-memory store in this slice). The output target defaults to
    /// `previewOnly` (a restored ad-hoc conversation has no live command target); a typed follow-up + Enter
    /// resumes the thread exactly as a fresh one does. Does NOT re-run the model.
    func restoreConversation(_ restored: AgentConversation) {
        generationTask?.cancel()
        generationTask = nil
        approvalGate?.resolve(.cancel); approvalGate = nil
        thinking = ""
        toolSteps = []
        canvasAtTop = true
        canvasAtBottom = true
        clearPendingAttachments()   // a restored thread starts with an empty composer (design D2)
        conversation = restored
        seedKind = .text
        conversationOutput = .previewOnly
        sessionReasoning = false
        sessionParameters = .default
        state = .awaitingTurn
    }

    // MARK: - Tool-step approval (task 2.8 — the canvas compass drives the route-loop gate)

    /// The `ApprovalGate` the bounded route loop awaits at a `.confirm`/`.dangerous` step. Hand this to an
    /// `AgentLoop`/`ToolRegistry.run(_:gate:)`; when a step pauses, the executor transitions to
    /// `.awaitingApproval(review)` (the canvas renders the review card) and the loop suspends until the
    /// canvas compass resolves it via `approve()` / `skip()`. Created fresh per loop so a prior pause never
    /// leaks. Retained so a discard can `.cancel` it.
    func makeApprovalGate() -> CanvasApprovalGate {
        let gate = CanvasApprovalGate(
            onAwait: { [weak self] review in self?.state = .awaitingApproval(review) },
            onResolve: { _ in })
        approvalGate = gate
        return gate
    }

    /// Record a tool step the route loop ran (the canvas renders the running list). Call from the loop's
    /// step sink. Resets implicitly when a fresh conversation opens.
    func appendToolStep(_ step: ToolStepResult) {
        toolSteps.append(step)
    }

    /// DOWN-when-`.awaitingApproval` resolves the pending step to `.approve` (task 2.8): the route loop
    /// resumes and fires the step. A no-op (returns false) when no step is pending — the consumer seam then
    /// falls through to the normal at-top commit path. Driven by the canvas compass at the `AppCoordinator`
    /// seam (the recognizer is untouched).
    @discardableResult
    func approve() -> Bool {
        approvalGate?.resolve(.approve) ?? false
    }

    /// RIGHT-when-`.awaitingApproval` resolves the pending step to `.skip` (task 2.8): the route loop
    /// resumes, declines the step, and the model may pivot. A no-op (returns false) when no step is pending.
    @discardableResult
    func skip() -> Bool {
        approvalGate?.resolve(.skip) ?? false
    }

    // MARK: - Conversation session (multi-turn)

    /// Open a NEW conversation from a seed — acquired input text and/or a per-turn image — that becomes
    /// turn 1 (design D4). The caller (the canvas slice) resolves the seed text the same way the one-shot
    /// path resolves its prompt. An empty-and-imageless seed surfaces `.noInput` and opens NO conversation
    /// (no model call), preserving the one-shot rule. Otherwise it streams the first assistant turn;
    /// progress is observed via `state` / `conversation`.
    func startConversation(seedText: String, image: Data? = nil,
                           parameters: GenerationParameters = .default, reasoning: Bool = false) {
        generationTask?.cancel()
        generationTask = nil
        thinking = ""
        canvasAtTop = true
        clearPendingAttachments()   // a fresh conversation open starts with an empty composer (design D2)

        // Same fire-time availability gate as the one-shot path: no model → `.unavailable`, never silence.
        guard modelManager.optedIn, Self.modelIsOnDisk(modelManager.state) else {
            state = .unavailable
            return
        }
        // Empty-and-imageless seed → no conversation, no model call (preserves `.noInput`).
        if seedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, image == nil {
            conversation = nil
            state = .noInput
            return
        }

        let now = Date()
        let seed = AgentMessage(role: .user, text: seedText, image: image, createdAt: now)
        conversation = AgentConversation(title: Self.conversationTitle(from: seedText),
                                         messages: [seed], createdAt: now, updatedAt: now)
        sessionReasoning = reasoning
        sessionParameters = parameters

        state = .loadingModel
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn()
        }
    }

    /// Continue the open conversation with the user's next turn (the entry the canvas calls on Enter =
    /// send): append the user message — text plus any `images` (design D2 / Bug 6) — and stream the
    /// assistant turn. No-op when no conversation is open, or when the text is empty AND no images are
    /// attached (an image-only follow-up is a valid turn). Supersedes any in-flight turn (a new send
    /// cancels the old). Clears the pending-attachments model once the images are folded onto the message.
    func continueConversation(_ userText: String, images: [Data] = []) {
        guard conversation != nil else { return }
        let turnImages = images.isEmpty ? pendingAttachments.images : images
        guard !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !turnImages.isEmpty else { return }

        generationTask?.cancel()
        let now = Date()
        conversation?.messages.append(AgentMessage(role: .user, text: userText, images: turnImages, createdAt: now))
        conversation?.updatedAt = now
        clearPendingAttachments()

        state = .loadingModel
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn()
        }
    }

    // MARK: - Composer attachments (design D2 / Bug 6)

    /// Stage the LIVE clipboard image (PNG) on the composer for the next turn (design D2). Reads via the
    /// injected `SelectionProviding.readClipboardImage()` (the live pasteboard, normalized to PNG — never
    /// `ClipboardStore`); a nil read (no image on the clipboard) is a no-op, not a failure. Returns whether
    /// an image was staged so the composer can give immediate feedback. The screenshot CAPTURE path is the
    /// coordinator's region picker (stage 3); see `attachScreenshot(_:)`.
    @discardableResult
    func attachClipboardImage() -> Bool {
        guard let png = selection.readClipboardImage() else { return false }
        pendingAttachments.images.append(png)
        return true
    }

    /// Stage a captured SCREENSHOT (PNG bytes) on the composer for the next turn (design D2). The capture
    /// itself is the coordinator's region picker (stage 3); this is the executor seam it hands the bytes to.
    func attachScreenshot(_ data: Data) {
        pendingAttachments.images.append(data)
    }

    /// Remove the staged attachment at `index` from the composer (the composer's per-chip delete). Out-of-
    /// range is a no-op.
    func removeAttachment(at index: Int) {
        guard pendingAttachments.images.indices.contains(index) else { return }
        pendingAttachments.images.remove(at: index)
    }

    /// Clear ALL staged composer attachments (design D2): called once a turn folds them onto its message,
    /// and whenever the session resets (discard / park / restore / a fresh conversation open).
    func clearPendingAttachments() {
        if !pendingAttachments.isEmpty { pendingAttachments = PendingAttachments() }
    }

    /// Discard the IN-FLIGHT turn of an open conversation (design D4): cancel generation, append no
    /// partial assistant message, and leave the thread open and idle — a mid-turn discard is NOT a
    /// failure. No-op when no conversation is open. (Ending a whole conversation is the canvas slice's
    /// concern; this only abandons the current turn.) Clears any staged composer attachments (design D2).
    func discardTurn() {
        guard conversation != nil else { return }
        generationTask?.cancel()
        generationTask = nil
        thinking = ""
        clearPendingAttachments()
        state = .awaitingTurn
    }

    /// Run one assistant turn over the open conversation (design D4): compact if needed (§4), assemble
    /// the request reading committed text ONLY (§5.5), stream the channel-split turn, then append the
    /// assistant message (response as `text`; reasoning retained as DISPLAY-only `thinking`) and go
    /// `.awaitingTurn`. A discard mid-turn appends nothing and is not a failure; a non-cancel error → a
    /// clean `.failed` (never silence, never a false continuation).
    private func runTurn() async {
        guard let current = conversation, !current.messages.isEmpty else { return }

        // Select + load a runtime for this turn's capabilities (vision iff any turn carries an image —
        // design D2: a turn may carry MULTIPLE images, so test the `images` array, not a single field).
        let needsVision = current.messages.contains { !$0.images.isEmpty }
        let caps: Set<Modality> = needsVision ? [.text, .vision] : [.text]
        let runtime: LLMRuntime
        do {
            runtime = try await modelManager.runtime(requiring: caps)
        } catch {
            state = .failed(message: Self.message(for: error))
            return
        }
        if Task.isCancelled { return }

        // Compaction (design D6): when the assembled estimate approaches the injected budget, collapse
        // older turns into a summary BEFORE assembling. A failed summarization is a turn `.failed` and
        // does NOT drop history (the plan applies only on a successful summary, so a retry sees it all).
        if ConversationCompactor.needsCompaction(current, budget: budgetProvider) {
            let plan = ConversationCompactor.plan(current)
            if !plan.isEmpty {
                do {
                    let summary = try await ConversationCompactor.summarize(plan, runtime: runtime)
                    if Task.isCancelled { return }
                    conversation = ConversationCompactor.applied(plan, summary: summary, to: current)
                } catch let error as RuntimeError {
                    if case .cancelled = error { return }
                    state = .failed(message: Self.message(for: error))
                    return
                } catch is CancellationError {
                    return
                } catch {
                    state = .failed(message: Self.message(for: error))
                    return
                }
            }
        }

        guard let request = assembleRequest() else { return }

        // Stream the turn: `.thinking` → live `thinking` (reset for this turn so it never shows the prior
        // turn's reasoning); `.response` → the in-flight `.conversing(partial:)` accumulation.
        thinking = ""
        state = .conversing(partial: "")
        var accumulated = ""
        do {
            for try await token in runtime.chat(request) {
                if Task.isCancelled { return }
                switch token.channel {
                case .thinking:
                    thinking += token.text
                case .response:
                    accumulated += token.text
                    state = .conversing(partial: accumulated)
                }
            }
            if Task.isCancelled { return }
            // Append the assistant turn: response only as `text`; reasoning retained for DISPLAY only and
            // NEVER re-fed (the structural invariant of `AgentMessage`).
            let now = Date()
            conversation?.messages.append(AgentMessage(role: .assistant, text: accumulated,
                                                       thinking: thinking.isEmpty ? nil : thinking,
                                                       createdAt: now))
            conversation?.updatedAt = now
            state = .awaitingTurn
        } catch let error as RuntimeError {
            if case .cancelled = error { return }   // a discard is not a failure
            state = .failed(message: Self.message(for: error))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(message: Self.message(for: error))
        }
    }

    /// Assemble the conversation into an `LLMChatRequest` (design D5): include each message reading its
    /// committed `text` ONLY (thinking is structurally excluded — `ChatTemplate.flatten` never reads it),
    /// prefixing any `compactedSummary` as a synthetic `system` message so the model still "remembers" the
    /// dropped turns. The latest image, session reasoning, and parameters ride along. nil when no
    /// conversation is open. `internal` (not private) so tests can assert assembly directly.
    func assembleRequest() -> LLMChatRequest? {
        guard let conversation else { return nil }
        var messages: [AgentMessage] = []
        if let summary = conversation.compactedSummary, !summary.isEmpty {
            messages.append(AgentMessage(role: .system, text: summary))
        }
        messages.append(contentsOf: conversation.messages)
        // Forward the latest turn's FULL images array (design D2: a turn may carry multiple images).
        let images = conversation.messages.last(where: { !$0.images.isEmpty })?.images ?? []
        return LLMChatRequest(messages: messages, images: images,
                              parameters: sessionParameters, reasoning: sessionReasoning)
    }

    /// A short conversation title from the seed's first non-empty line; a generic fallback for an
    /// image-only/empty seed. (A model-derived smart title is left to a later slice — see the roadmap's
    /// open question on title derivation.)
    private static func conversationTitle(from seedText: String) -> String {
        let firstLine = seedText.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if firstLine.isEmpty { return "Conversation" }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
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
        case .clipboardImage, .screenRegion, .none:
            return nil
        }
    }

    /// Whether a source needs non-empty text before the model may run (the image sources
    /// `clipboardImage` / `screenRegion` carry an image, not text; `none` needs nothing).
    private func requiresTextInput(_ source: InputSource) -> Bool {
        switch source {
        case .selection, .clipboard: return true
        case .clipboardImage, .screenRegion, .none: return false
        }
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
