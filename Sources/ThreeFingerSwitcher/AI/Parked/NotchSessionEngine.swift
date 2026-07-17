import Foundation
import Combine

/// The transient set of images staged on a notch composer before the next send. Pure value — the engine
/// owns it; the expanded conversation view renders/edits it via the engine's attach/remove seams. `text`
/// is reserved for a future staged-text affordance; today only `images` is populated.
struct PendingAttachments: Equatable {
    /// Staged images for the next turn (each PNG); folded into the next user message's `images`.
    var images: [Data] = []
    /// Whether anything is staged (drives the composer's "has attachments" affordance).
    var isEmpty: Bool { images.isEmpty }
}

/// The multi-turn conversation machine for ONE notch session (`notch-native-conversations` design D1) —
/// the executor's conversational half re-homed. The launcher's `AICommandExecutor` is one-shot-only again;
/// every typed conversation lives at the notch, driven by an instance of this engine bound to a durable
/// `AgentConversation` from the parked store. `ParkController` owns the instances (one per session with a
/// live foreground turn; exactly one is bound to the expanded panel at a time) — the engine itself knows
/// nothing about panels, stores, or schedulers; it reports through `onTurnSettled`/`onTaskComplete`.
///
/// What deliberately did NOT move here from the executor (canvas-era concepts with no notch meaning):
/// seed acquisition (`SeedKind`/`BareSeedDefault` — a notch session starts from typing), output routing
/// (`extractLatest` — the notch writes nothing into other apps; the expanded view offers Copy), and the
/// at-top/at-bottom gesture gates (the notch is a cursor-and-keyboard surface).
///
/// `@MainActor` + `ObservableObject`: it holds observable UI state, matching the executor convention.
@MainActor
final class NotchSessionEngine: ObservableObject {

    /// The engine's observable state — the conversational subset of the old executor contract.
    enum State: Equatable {
        /// No session bound / the session was discarded.
        case idle
        /// AI can't run a turn yet: the opt-in is off or the model isn't downloaded/ready. The bound
        /// conversation is KEPT (it is durable) — the expanded view offers enable/download and a later
        /// send retries.
        case unavailable
        /// Resolving + loading the model for a turn (a visible state, never a silent block).
        case loadingModel
        /// An assistant turn is streaming; `partial` is the response-channel accumulation.
        case conversing(partial: String)
        /// The thread is idle, awaiting the next user turn (Enter = send, from the composer).
        case awaitingTurn
        /// The route loop paused at a `.confirm`/`.dangerous` tool step: the expanded view renders the
        /// carried `TaskReview` as a card with Approve / Skip buttons.
        case awaitingApproval(TaskReview)
        /// A typed failure with a clean, human-readable headline (never raw error text).
        case failed(message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.unavailable, .unavailable), (.loadingModel, .loadingModel),
                 (.awaitingTurn, .awaitingTurn):
                return true
            case let (.conversing(a), .conversing(b)): return a == b
            case let (.failed(a), .failed(b)): return a == b
            case let (.awaitingApproval(a), .awaitingApproval(b)): return TaskReview.previewEqual(a, b)
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// The model's streamed REASONING for the in-flight turn — live into the expanded view's collapsible
    /// Thinking section; retained on the appended assistant message for DISPLAY only, NEVER re-fed.
    @Published private(set) var thinking: String = ""
    /// The ordered tool steps the route loop has run for the current turn (the expanded view renders a
    /// compact list of `ToolStepResult.summary`). Reset per turn.
    @Published private(set) var toolSteps: [ToolStepResult] = []
    /// The composer's staged attachments for the NEXT user turn. The attach UI is a documented future;
    /// the seams are kept so `send(_:images:)` remains capable (design: Non-Goals).
    @Published private(set) var pendingAttachments = PendingAttachments()
    /// The bound conversation — durable ownership stays with the parked store; the engine holds it for
    /// the session's foreground life and hands snapshots back through `unbind`/`onTurnSettled`.
    private(set) var conversation: AgentConversation?

    /// How a turn ended — the controller's row/badge classification input. There is deliberately NO
    /// "task complete" notion (`refactor-park-and-background-agents`): a settled answer is an unseen
    /// result, never a terminal state that removes the session.
    enum TurnSettlement: Equatable {
        /// The turn produced/updated the thread normally (an answer, or a routed stop with text).
        case answered
        /// The loop paused on a background approval — no assistant message was fabricated; the pending
        /// step waits on the user (dormant parked, or needs-you when it escalated).
        case pausedAwaitingUser
        /// The turn failed with a clean headline (observable, never silent) — a detached failure
        /// re-parks with a scheduled retry via the advance-feedback seam.
        case failed(headline: String)
    }

    /// Reports EVERY settled turn (streamed answer appended, routed outcome appended, a paused loop, or
    /// a turn failure) with a durable snapshot + how it ended. The controller persists the snapshot and
    /// updates the row/badge. Fires for detached (collapsed mid-turn) sessions too — that is the
    /// "collapse does not cancel" contract.
    var onTurnSettled: (@MainActor (AgentConversation, TurnSettlement) -> Void)?

    /// Fires when the route loop pauses at THIS engine's approval gate (state → `.awaitingApproval`).
    /// The controller surfaces `.needsYou` when the session is detached — a confirm/dangerous step that
    /// arises AFTER the user docked would otherwise suspend invisibly behind a "Working…" badge.
    var onApprovalPending: (@MainActor () -> Void)?

    /// Fires when a user turn is SENT — the user message has been appended (and the session named), BEFORE
    /// the model-availability gate. Lets the controller PERSIST a session that was unsaved until its first
    /// message: an empty new chat writes nothing to the store (it is never docked, and is discarded if
    /// closed empty); the first message makes it durable + joins the dock. Fires on every send (the
    /// controller's upsert is idempotent). Does NOT fire for an empty/whitespace send.
    var onTurnStarted: (@MainActor (AgentConversation) -> Void)?

    private let modelManager: ModelManager
    private let selection: SelectionProviding
    private let contextProvider: @MainActor () -> FireContext
    private let reasoningDefault: @MainActor () -> Bool
    private let budgetProvider: ContextBudgetProviding
    private let registry: ToolRegistry?
    private let candidateSource: ToolCandidateSource?
    private let skillTools: @MainActor (String) -> [String]
    private let backgroundRunner: BackgroundToolRunner?

    private var sessionReasoning = false
    private var sessionParameters: GenerationParameters = .default
    private var generationTask: Task<Void, Never>?
    private var approvalGate: CanvasApprovalGate?

    init(modelManager: ModelManager,
         selection: SelectionProviding,
         contextProvider: @escaping @MainActor () -> FireContext = { FireContext() },
         reasoning: @escaping @MainActor () -> Bool = { false },
         budgetProvider: ContextBudgetProviding = DefaultContextBudget(),
         registry: ToolRegistry? = nil,
         candidateSource: ToolCandidateSource? = nil,
         skillTools: @escaping @MainActor (String) -> [String] = { _ in [] },
         backgroundRunner: BackgroundToolRunner? = nil) {
        self.modelManager = modelManager
        self.selection = selection
        self.contextProvider = contextProvider
        self.reasoningDefault = reasoning
        self.budgetProvider = budgetProvider
        self.registry = registry
        self.candidateSource = candidateSource
        self.skillTools = skillTools
        self.backgroundRunner = backgroundRunner
    }

    /// Whether a turn is currently being produced (loading, streaming, OR paused at the approval gate) —
    /// the controller reads this on collapse to decide whether the engine must be kept alive detached
    /// until the turn settles. `.awaitingApproval` COUNTS as in flight: the route loop is suspended on
    /// this engine's gate, and dropping the engine would orphan the suspended continuation (the
    /// docked-mid-approval bug — the response stops forever and the idle row expires).
    var isTurnInFlight: Bool {
        switch state {
        case .loadingModel, .conversing, .awaitingApproval: return true
        default: return false
        }
    }

    /// Whether the in-flight turn is paused at the foreground approval gate (the suspended continuation
    /// lives in this engine's `approvalGate`). The controller surfaces `.needsYou` when such a session
    /// is docked; re-expanding re-presents the same card and Approve/Skip resumes the original step.
    var isPausedAtApproval: Bool {
        if case .awaitingApproval = state { return true }
        return false
    }

    /// Whether the turn is actively PRODUCING (loading or streaming) — as opposed to suspended at the
    /// approval gate, which consumes no generation slot. The background driver counts only these when
    /// deciding whether the single slot is taken (a session paused on the user must never block other
    /// sessions from advancing).
    var isGenerating: Bool {
        switch state {
        case .loadingModel, .conversing: return true
        default: return false
        }
    }

    // MARK: - Session verbs (the ParkController seam)

    /// Start a NEW session: a fresh, empty conversation with a stable identity, idling for its first
    /// typed turn. The controller persists it immediately (durable at birth) and expands it.
    func startNew(title: String = "New chat") -> AgentConversation {
        cancelTurnMachinery()
        let now = Date()
        let fresh = AgentConversation(title: title, messages: [], createdAt: now, updatedAt: now)
        conversation = fresh
        sessionReasoning = reasoningDefault()
        sessionParameters = .default
        thinking = ""
        toolSteps = []
        clearPendingAttachments()
        state = .awaitingTurn
        return fresh
    }

    /// Bind a stored conversation for foreground use (the card was expanded). Idles in `.awaitingTurn`;
    /// a session that had escalated re-presents its approval on the next turn's route loop (the pending
    /// decision is not modeled by the durable store — the restore-era behavior, unchanged).
    func bind(_ stored: AgentConversation) {
        cancelTurnMachinery()
        conversation = stored
        sessionReasoning = reasoningDefault()
        sessionParameters = .default
        thinking = ""
        toolSteps = []
        clearPendingAttachments()
        state = .awaitingTurn
    }

    /// Detach the engine from the expanded panel (collapse). Returns the current snapshot for the
    /// controller to persist. Does NOT cancel an in-flight turn — the turn keeps streaming detached and
    /// reports through `onTurnSettled` when it lands (the spec's collapse-mid-turn contract). When no
    /// turn is in flight the engine fully resets to `.idle`.
    @discardableResult
    func unbind() -> AgentConversation? {
        let snapshot = conversation
        clearPendingAttachments()
        if !isTurnInFlight {
            conversation = nil
            thinking = ""
            toolSteps = []
            state = .idle
        }
        return snapshot
    }

    /// Tear the session down entirely (the authoritative discard path): cancel any pending generation
    /// (a cancellation is NOT a failure), resolve a pending approval to cancel, drop the conversation.
    func cancelAll() {
        cancelTurnMachinery()
        conversation = nil
        thinking = ""
        toolSteps = []
        clearPendingAttachments()
        state = .idle
    }

    private func cancelTurnMachinery() {
        generationTask?.cancel()
        generationTask = nil
        approvalGate?.resolve(.cancel)
        approvalGate = nil
    }

    // MARK: - Turns

    /// Send the next user turn (Enter from the composer): append the message — text plus any staged or
    /// passed `images` — and stream the assistant turn. The FIRST turn of a new session also names it
    /// (title from the first line). No-op when no conversation is bound, or when the text is empty AND
    /// no images ride along. Supersedes any in-flight turn. Availability-gated: no model → `.unavailable`
    /// with the conversation kept (a later send retries).
    func send(_ text: String, images: [Data] = []) {
        guard conversation != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnImages = images.isEmpty ? pendingAttachments.images : images
        guard !trimmed.isEmpty || !turnImages.isEmpty else { return }

        generationTask?.cancel()
        let now = Date()
        // First turn names a fresh session (title was the "New chat" placeholder until now).
        if conversation?.messages.isEmpty == true {
            conversation?.title = Self.sessionTitle(from: trimmed)
        }
        conversation?.messages.append(AgentMessage(role: .user, text: text, images: turnImages, createdAt: now))
        conversation?.updatedAt = now
        clearPendingAttachments()
        // The user's first message makes the session durable + docked (`newSession` persists nothing until
        // now). Appended BEFORE the availability gate, so a missing model shows the unavailable hint without
        // dropping — or un-saving — what the user typed.
        if let convo = conversation { onTurnStarted?(convo) }

        guard modelManager.optedIn, AICommandExecutor.modelIsOnDisk(modelManager.state) else {
            state = .unavailable
            return
        }

        state = .loadingModel
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn()
        }
    }

    /// Advance the bound conversation WITHOUT a new user turn — the background driver's verb
    /// (`refactor-park-and-background-agents`): run the PENDING turn of a conversation whose last
    /// message still awaits an assistant reply (a quit-mid-turn session recovered at relaunch, or a
    /// scheduled retry after a failed advance). No-op when nothing is pending. Availability-gated like
    /// `send` (no model → `.unavailable` with the conversation kept).
    func advance() {
        guard let current = conversation,
              let last = current.messages.last, last.role != .assistant else { return }
        guard modelManager.optedIn, AICommandExecutor.modelIsOnDisk(modelManager.state) else {
            state = .unavailable
            return
        }
        generationTask?.cancel()
        state = .loadingModel
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn()
        }
    }

    /// Discard the IN-FLIGHT turn only: cancel generation, append no partial assistant message, leave
    /// the thread open and idle — a mid-turn discard is NOT a failure. No-op when nothing is bound.
    func discardTurn() {
        guard conversation != nil else { return }
        generationTask?.cancel()
        generationTask = nil
        approvalGate?.resolve(.cancel)
        approvalGate = nil
        thinking = ""
        state = .awaitingTurn
    }

    // MARK: - Tool-step approval (the expanded view's Approve/Skip buttons drive the route-loop gate)

    /// The `ApprovalGate` the bounded route loop awaits at a `.confirm`/`.dangerous` step. When a step
    /// pauses, the engine transitions to `.awaitingApproval(review)` (the expanded view renders the card)
    /// and the loop suspends until `approve()` / `skip()` resolves it. Created fresh per loop.
    func makeApprovalGate() -> CanvasApprovalGate {
        let gate = CanvasApprovalGate(
            onAwait: { [weak self] review in
                self?.state = .awaitingApproval(review)
                self?.onApprovalPending?()
            },
            onResolve: { _ in })
        approvalGate = gate
        return gate
    }

    /// The Approve button resolves the pending step to `.approve`; the route loop resumes and fires the
    /// step. Returns false when no step is pending.
    @discardableResult
    func approve() -> Bool {
        approvalGate?.resolve(.approve) ?? false
    }

    /// The Skip button resolves the pending step to `.skip`; the loop resumes, declines the step, and
    /// the model may pivot. Returns false when no step is pending.
    @discardableResult
    func skip() -> Bool {
        approvalGate?.resolve(.skip) ?? false
    }

    /// Record a tool step the route loop ran (the expanded view renders the running list).
    func appendToolStep(_ step: ToolStepResult) {
        toolSteps.append(step)
    }

    // MARK: - Composer attachments (API kept; the attach UI is a documented future)

    /// Stage the LIVE clipboard image (PNG) for the next turn. Reads via the injected
    /// `SelectionProviding.readClipboardImage()` (the live pasteboard, normalized to PNG); a nil read is
    /// a no-op, not a failure. Returns whether an image was staged.
    @discardableResult
    func attachClipboardImage() -> Bool {
        guard let png = selection.readClipboardImage() else { return false }
        pendingAttachments.images.append(png)
        return true
    }

    /// Stage captured screenshot bytes for the next turn (the capture itself is the caller's concern).
    func attachScreenshot(_ data: Data) {
        pendingAttachments.images.append(data)
    }

    /// Remove the staged attachment at `index`. Out-of-range is a no-op.
    func removeAttachment(at index: Int) {
        guard pendingAttachments.images.indices.contains(index) else { return }
        pendingAttachments.images.remove(at: index)
    }

    /// Clear ALL staged attachments: once a turn folds them onto its message, and on every session reset.
    func clearPendingAttachments() {
        if !pendingAttachments.isEmpty { pendingAttachments = PendingAttachments() }
    }

    // MARK: - The turn loop (moved wholesale from the executor's conversational half)

    /// Run one assistant turn over the bound conversation: compact if needed, assemble the request
    /// reading committed text ONLY, stream the channel-split turn, then append the assistant message
    /// (response as `text`; reasoning retained as DISPLAY-only `thinking`), go `.awaitingTurn`, and
    /// report the settled snapshot. A discard mid-turn appends nothing and is not a failure; a
    /// non-cancel error → a clean `.failed` (never silence, never a false continuation).
    private func runTurn() async {
        guard let current = conversation, !current.messages.isEmpty else { return }

        // Select + load a runtime for this turn's capabilities (vision iff any turn carries an image).
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

        // Compaction: when the assembled estimate approaches the injected budget, collapse older turns
        // into a summary BEFORE assembling. A failed summarization is a turn `.failed` and does NOT drop
        // history (the plan applies only on a successful summary, so a retry sees it all).
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

        // The tool-routing path: when a registry + candidate source are wired, the turn runs the bounded
        // route → execute → continue loop so the model is offered the app's tools. The plain-chat path
        // below is unchanged for the `registry == nil` case (tests with a bare runtime).
        if let registry, let candidateSource {
            await runRoutedTurn(runtime: runtime, registry: registry, candidateSource: candidateSource)
            return
        }

        guard let request = assembleRequest() else { return }

        // Stream the turn: `.thinking` → live `thinking` (reset per turn); `.response` → `.conversing`.
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
            appendAssistantTurn(accumulated)
        } catch let error as RuntimeError {
            if case .cancelled = error { return }   // a discard is not a failure
            state = .failed(message: Self.message(for: error))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(message: Self.message(for: error))
        }
    }

    /// Run one assistant turn through the bounded route → execute → continue loop: build a
    /// `RouteContext` from the conversation (committed `text` is the only re-fed content; the active
    /// skill's `toolNames` resolve into `allowedTools`), drive an `AgentLoop` with this engine's approval
    /// gate, record each step, and settle the terminal outcome. `.failed` becomes a clean, non-blocking
    /// `.failed` state; a `.cancelled` discard appends nothing and is not a failure.
    private func runRoutedTurn(runtime: LLMRuntime, registry: ToolRegistry,
                               candidateSource: ToolCandidateSource) async {
        guard let current = conversation else { return }

        let allowed = current.skillID.map { skillTools($0) } ?? []
        let context = RouteContext(messages: current.messages,
                                   activeSkillID: current.skillID,
                                   allowedTools: allowed)
        let gate = makeApprovalGate()

        thinking = ""
        toolSteps = []
        state = .conversing(partial: "")

        // Ordered, turn-owned reasoning stream: the loop yields tokens (off-main) into the stream and
        // ONE consumer appends them in order on the main actor, drained before the turn settles. The
        // old per-token detached `Task`s were unordered and could land after settlement or discard.
        var streamContinuation: AsyncStream<String>.Continuation!
        let tokens = AsyncStream<String> { streamContinuation = $0 }
        let continuation = streamContinuation!
        let consumer = Task { [weak self] in
            for await text in tokens { self?.thinking += text }
        }

        let fireContext = contextProvider()
        let source = TaskSource(appName: fireContext.capturedAppName, url: fireContext.url,
                                timestamp: fireContext.date)
        let loop = AgentLoop(runtime: runtime, registry: registry, candidateSource: candidateSource,
                             gate: gate, reasoning: sessionReasoning, source: source,
                             onThinking: { continuation.yield($0) },
                             sessionID: current.id,
                             backgroundRunner: backgroundRunner)
        let result = await loop.run(context: context)
        continuation.finish()
        await consumer.value
        if Task.isCancelled { return }

        toolSteps = result.steps

        switch result.outcome {
        case let .answered(text), let .capReached(text):
            appendAssistantTurn(text)
        case let .stopped(reason, text):
            if reason == .cancelled { return }   // a discard appends nothing and is not a failure
            appendAssistantTurn(text)
        case .pausedAwaitingUser:
            // The loop paused on a background approval: the steps are recorded, NO assistant message is
            // fabricated, and the snapshot settles so the controller classifies the row (dormant parked,
            // or needs-you when the step escalated). The pending decision re-presents restore-era style.
            state = .awaitingTurn
            if let settled = conversation { onTurnSettled?(settled, .pausedAwaitingUser) }
        case let .failed(headline):
            state = .failed(message: headline)
            // A failure still settles the turn (the user message is in the thread) so a collapsed
            // session's snapshot persists what happened and a detached advance can schedule a retry.
            if let settled = conversation { onTurnSettled?(settled, .failed(headline: headline)) }
        }
    }

    /// Append the assistant turn (response only as `text`; thinking retained for DISPLAY only and NEVER
    /// re-fed), return to `.awaitingTurn`, and report the settled snapshot to the controller.
    private func appendAssistantTurn(_ text: String) {
        let now = Date()
        conversation?.messages.append(AgentMessage(role: .assistant, text: text,
                                                   thinking: thinking.isEmpty ? nil : thinking,
                                                   createdAt: now))
        conversation?.updatedAt = now
        state = .awaitingTurn
        if let settled = conversation { onTurnSettled?(settled, .answered) }
    }

    /// Assemble the conversation into an `LLMChatRequest`: each message's committed `text` ONLY
    /// (thinking is structurally excluded), any `compactedSummary` prefixed as a synthetic `system`
    /// message, the latest turn's images, session reasoning + parameters. `internal` so tests can
    /// assert assembly directly.
    func assembleRequest() -> LLMChatRequest? {
        guard let conversation else { return nil }
        var messages: [AgentMessage] = []
        if let summary = conversation.compactedSummary, !summary.isEmpty {
            messages.append(AgentMessage(role: .system, text: summary))
        }
        messages.append(contentsOf: conversation.messages)
        let images = conversation.messages.last(where: { !$0.images.isEmpty })?.images ?? []
        return LLMChatRequest(messages: messages, images: images,
                              parameters: sessionParameters, reasoning: sessionReasoning)
    }

    /// A short session title from the first turn's first non-empty line; the generic placeholder stays
    /// for an image-only first turn.
    private static func sessionTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if firstLine.isEmpty { return "New chat" }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    /// One taxonomy, one translator: every failure surfaces the same clean headline everywhere.
    private static func message(for error: Error) -> String {
        AIError.message(for: error).headline
    }
}
