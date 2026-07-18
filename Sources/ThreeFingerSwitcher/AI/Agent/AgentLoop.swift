import Foundation

/// Why a bounded loop stopped short of a plain answer.
enum AgentStopReason: Equatable, Sendable {
    case repeatedStep   // a byte-identical route to the immediately preceding executed call (spinning)
    case noProgress     // re-routed to a tool that already declined/failed more than once
    case cancelled      // the user discarded the canvas (a discard, never a failure)
}

/// The terminal outcome of the bounded agent loop (design D7). Every text-carrying outcome holds the
/// best-effort final answer — the loop NEVER ends with a bare halt. `.pausedAwaitingUser` is the one
/// deliberate exception (`refactor-park-and-background-agents`): a background approval pause ends the
/// turn with NO fabricated answer — the pending step is observable state, not a completion. There is no
/// "task complete" notion here anymore: the old terminal classification let a docked chat's settled
/// answer auto-dismiss (delete) its session.
enum AgentLoopOutcome: Equatable, Sendable {
    case answered(text: String)
    case capReached(text: String)
    case stopped(reason: AgentStopReason, text: String)
    /// A step is pending on the user (background waitParked/escalate): the loop pauses honestly — the
    /// step is neither run nor skipped, and no final answer is synthesized.
    case pausedAwaitingUser
    case failed(headline: String)
}

/// The loop's full result: the outcome plus the ordered tool steps it ran (the canvas binds these as
/// observable state; tests assert them).
struct AgentLoopResult: Sendable {
    var outcome: AgentLoopOutcome
    var steps: [ToolStepResult]
}

/// The loop's wall-clock bounds (`add-voice-computer-use-agent`, design D8): a per-step timeout and
/// a per-turn deadline. Both are BUDGET errors, not runtime errors — a timed-out step settles
/// `.failed("… timed out")` (never a misleading network headline) and an exceeded deadline
/// terminates via the existing cap-reached fallback. Human time is exempt: a step that pauses at
/// the approval gate is never step-timed, and the deadline re-baselines after it (a user thinking
/// about an approval must not spend the agent's budget).
struct LoopBudget: Sendable {
    /// Per-step wall clock for NON-GATED dispatches (auto tier / auto-granted). Seconds.
    var stepTimeout: TimeInterval
    /// Total active wall clock for the whole turn. Seconds.
    var turnDeadline: TimeInterval

    static let `default` = LoopBudget(stepTimeout: 30, turnDeadline: 180)
}

/// The bounded route → execute → continue loop (design D7), pure Core, owns no UI. It drives an injected
/// `LLMRuntime` (the batched conformer in production, `StubLLMRuntime` in tests), routes via
/// `structured()`, dispatches through the `ToolRegistry`, and is bounded by a hard step cap plus two
/// loop-guards — and, since `add-voice-computer-use-agent`, the wall-clock `LoopBudget`. The running
/// plan rides the existing `.thinking` channel via `onThinking`; the committed answer is
/// `.response`-channel only.
struct AgentLoop: Sendable {
    let runtime: LLMRuntime
    let registry: ToolRegistry
    let candidateSource: ToolCandidateSource
    let gate: ApprovalGate
    let reasoning: Bool
    let maxToolSteps: Int
    let source: TaskSource
    /// Live plan sink: each route rationale + tool-step summary is emitted here (the canvas renders it in
    /// its collapsible Thinking section). Default no-op.
    let onThinking: @Sendable (String) -> Void
    /// Live RESPONSE-token sink (`add-voice-computer-use-agent`): the final answer's `.response`
    /// tokens stream here AS they generate — the voice surface feeds its sentence chunker from this
    /// so the first sentence speaks before the loop returns. Default no-op (the canvas keeps reading
    /// the returned text).
    let onResponseToken: @Sendable (String) -> Void
    /// The session this loop advances — audited + park-state-keyed by `ai-background-autonomy`. Defaults
    /// to a fresh id for the foreground one-shot loop.
    let sessionID: AgentSessionID
    /// Optional background-policy runner (`ai-background-autonomy`, 6.1–6.4): when present, each tool step
    /// routes through it (whitelist-aware tier → `BackgroundGate` decision → run/escalate/wait + audit)
    /// instead of calling `registry.run` directly. nil = the plain foreground path (existing behavior).
    let backgroundRunner: BackgroundToolRunner?
    /// The wall-clock bounds (design D8). Defaults keep pre-change behavior practically unchanged.
    let budget: LoopBudget
    /// Whether the conversation's auto-approve grant is live (the same signal the gate wrapper reads):
    /// a `.confirm` step under the grant cannot pause on a human, so it IS step-timed.
    let isAutoGranted: @Sendable () -> Bool
    /// Injected clock so deadline behavior is deterministically testable.
    let clock: @Sendable () -> Date

    init(runtime: LLMRuntime, registry: ToolRegistry, candidateSource: ToolCandidateSource,
         gate: ApprovalGate, reasoning: Bool = false, maxToolSteps: Int = 8,
         source: TaskSource = TaskSource(), onThinking: @escaping @Sendable (String) -> Void = { _ in },
         sessionID: AgentSessionID = AgentSessionID(), backgroundRunner: BackgroundToolRunner? = nil,
         budget: LoopBudget = .default,
         isAutoGranted: @escaping @Sendable () -> Bool = { false },
         clock: @escaping @Sendable () -> Date = { Date() },
         onResponseToken: @escaping @Sendable (String) -> Void = { _ in }) {
        self.runtime = runtime
        self.registry = registry
        self.candidateSource = candidateSource
        self.gate = gate
        self.reasoning = reasoning
        self.maxToolSteps = maxToolSteps
        self.source = source
        self.onThinking = onThinking
        self.sessionID = sessionID
        self.backgroundRunner = backgroundRunner
        self.budget = budget
        self.isAutoGranted = isAutoGranted
        self.clock = clock
        self.onResponseToken = onResponseToken
    }

    func run(context initial: RouteContext) async -> AgentLoopResult {
        var context = initial
        var steps: [ToolStepResult] = []
        var lastRoute: ToolRoute?
        var candidateLimit = 5
        var declineCount: [String: Int] = [:]
        // The turn deadline's baseline. Re-baselined after any step that could pause on a human
        // (approval wait is the USER's time, never the agent's budget).
        var deadlineStart = clock()

        for _ in 0 ..< max(1, maxToolSteps) {
            if Task.isCancelled { return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps) }
            // The turn deadline (design D8): exceeded → terminate through the existing cap-reached
            // fallback with an honest partial summary.
            if budget.turnDeadline > 0, clock().timeIntervalSince(deadlineStart) > budget.turnDeadline {
                onThinking("Ran out of time for this turn.\n")
                return await answer(context, steps: steps, terminator: .cap)
            }

            // Retrieve candidates (~5) and always offer the widen tool so the model can ask for more.
            var candidates = candidateSource.candidates(for: context, limit: candidateLimit)
            candidates.append(.widenCandidates)

            switch await ToolRouter.route(context: context, candidates: candidates,
                                          runtime: runtime, reasoning: reasoning) {
            case .cancelled:
                return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps)
            case let .failed(headline):
                return AgentLoopResult(outcome: .failed(headline: headline), steps: steps)
            case let .route(route):
                if let rationale = route.rationale, !rationale.isEmpty { onThinking(rationale + "\n") }

                if route.isPlainAnswer {
                    return await answer(context, steps: steps, terminator: .plain)
                }
                if route.tool == ToolDescriptor.widenCandidates.name {
                    candidateLimit = min(candidateLimit + 5, 20)
                    onThinking("Looking for more tools…\n")
                    continue
                }
                guard let descriptor = registry.descriptor(named: route.tool) else {
                    return await answer(context, steps: steps, terminator: .plain)   // defensive (router normalizes)
                }
                // Loop-guard: a byte-identical consecutive route means the model is spinning.
                if let last = lastRoute, last.tool == route.tool, last.argumentsJSON == route.argumentsJSON {
                    return await answer(context, steps: steps, terminator: .stopped(.repeatedStep))
                }

                let call = RoutedCall(descriptor: descriptor, route: route,
                                      userText: context.latestUserText, source: source)
                // A step that may PAUSE ON A HUMAN (confirm/dangerous without the auto grant) is
                // never step-timed, and the deadline re-baselines after it — approval wait is user
                // time. Everything else races the step timeout (design D8).
                let mayPauseOnHuman = descriptor.writePolicy != .auto && !isAutoGranted()
                // Background-autonomy path (6.1–6.4): when a runner is injected, each step routes through
                // it (whitelist-aware tier → BackgroundGate → run/escalate/wait + audit); otherwise the
                // plain foreground run is unchanged.
                let result = await dispatch(call, timed: !mayPauseOnHuman)
                if mayPauseOnHuman { deadlineStart = clock() }
                steps.append(result)
                if !result.summary.isEmpty { onThinking(result.summary + "\n") }
                context.messages.append(AgentMessage(role: .tool, text: result.summary, toolResult: result))
                lastRoute = route

                switch result.status {
                case let .failed(headline):
                    // A side effect that didn't land — surface it and stop (never a false "Done").
                    return AgentLoopResult(outcome: .failed(headline: headline), steps: steps)
                case let .declined(reason):
                    if reason == TaskKindToolContributor.cancelledReason {
                        return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps)
                    }
                    // No-progress guard: re-declining the same tool more than once terminates.
                    declineCount[route.tool, default: 0] += 1
                    if declineCount[route.tool, default: 0] > 1 {
                        return await answer(context, steps: steps, terminator: .stopped(.noProgress))
                    }
                    continue   // the model sees the decline and may pivot
                case .done:
                    continue
                case .awaitingApproval:
                    // Only the BACKGROUND runner returns this status as a result (the foreground gate
                    // resolves inside the contributor's await, yielding done/declined): the step is
                    // pending on the user — pause the turn honestly. Continuing here would neither run
                    // nor suspend the step and would fabricate a final answer over phantom work.
                    return AgentLoopResult(outcome: .pausedAwaitingUser, steps: steps)
                }
            }
        }
        // The hard cap is the backstop regardless of progress.
        return await answer(context, steps: steps, terminator: .cap)
    }

    // MARK: - Dispatch with the step timeout

    /// Run one routed call, racing the step timeout when `timed`. A timed-out step CANCELS its work
    /// (tools are cancellation-safe by contract) and settles `.failed("… timed out")` — a clean
    /// budget headline, never a fabricated success and never a misleading network error.
    private func dispatch(_ call: RoutedCall, timed: Bool) async -> ToolStepResult {
        let runStep: @Sendable () async -> ToolStepResult = { [self] in
            if let runner = backgroundRunner {
                return await runner.run(call, sessionID: sessionID, registry: registry, gate: gate)
            }
            return await registry.run(call, gate: gate)
        }
        guard timed, budget.stepTimeout > 0 else { return await runStep() }

        return await withTaskGroup(of: ToolStepResult?.self) { group in
            group.addTask { await runStep() }
            group.addTask { [stepTimeout = budget.stepTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(stepTimeout * 1_000_000_000))
                return nil   // the timeout sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let result = first { return result }
            return ToolStepResult(
                tool: call.descriptor.name,
                status: .failed(headline: "“\(call.descriptor.name)” timed out."),
                summary: "“\(call.descriptor.name)” didn't finish within \(Int(budget.stepTimeout))s and was stopped.")
        }
    }

    // MARK: - Final answer

    private enum Terminator {
        case plain
        case cap
        case stopped(AgentStopReason)
    }

    /// Stream a best-effort final text answer over the (possibly tool-augmented) context, then wrap it in
    /// the right terminal outcome. Cancellation during this is a quiet `.cancelled` (a discard).
    private func answer(_ context: RouteContext, steps: [ToolStepResult], terminator: Terminator) async -> AgentLoopResult {
        var text = ""
        do {
            for try await token in runtime.chat(LLMChatRequest(messages: context.messages, reasoning: reasoning)) {
                if Task.isCancelled { return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps) }
                switch token.channel {
                case .response:
                    text += token.text
                    onResponseToken(token.text)
                case .thinking:
                    onThinking(token.text)
                }
            }
        } catch let error as RuntimeError where error == .cancelled {
            return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps)
        } catch is CancellationError {
            return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps)
        } catch {
            return AgentLoopResult(outcome: .failed(headline: AIError.message(for: error).headline), steps: steps)
        }
        if Task.isCancelled { return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps) }

        switch terminator {
        case .plain: return AgentLoopResult(outcome: .answered(text: text), steps: steps)
        case .cap: return AgentLoopResult(outcome: .capReached(text: text), steps: steps)
        case let .stopped(reason): return AgentLoopResult(outcome: .stopped(reason: reason, text: text), steps: steps)
        }
    }
}
