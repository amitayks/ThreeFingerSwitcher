import Foundation

/// Why a bounded loop stopped short of a plain answer.
enum AgentStopReason: Equatable, Sendable {
    case repeatedStep   // a byte-identical route to the immediately preceding executed call (spinning)
    case noProgress     // re-routed to a tool that already declined/failed more than once
    case cancelled      // the user discarded the canvas (a discard, never a failure)
}

/// The terminal outcome of the bounded agent loop (design D7). Every outcome except `.cancelled` carries
/// the best-effort final answer text — the loop NEVER ends with a bare halt.
enum AgentLoopOutcome: Equatable, Sendable {
    case answered(text: String)
    case capReached(text: String)
    case stopped(reason: AgentStopReason, text: String)
    case failed(headline: String)

    /// Whether this outcome represents the TASK having FINISHED (design D1 / Bug 3 terminal detection):
    /// a plain answer, the bounded cap, or a `.stopped` with nothing pending all mean the work is done
    /// and the parked row may auto-dismiss forever. `.cancelled` (a discard, not a completion) and
    /// `.failed` (an observable failure the user may want to retry) are EXCLUDED — neither marks terminal.
    /// A `.stopped(reason: .cancelled)` is a discard, never a completion.
    var isTaskComplete: Bool {
        switch self {
        case .answered, .capReached:
            return true
        case let .stopped(reason, _):
            // A stop-with-no-pending (spinning / no-progress) is a completed task; a cancellation is not.
            return reason != .cancelled
        case .failed:
            return false
        }
    }
}

/// The loop's full result: the outcome plus the ordered tool steps it ran (the canvas binds these as
/// observable state; tests assert them).
struct AgentLoopResult: Sendable {
    var outcome: AgentLoopOutcome
    var steps: [ToolStepResult]
}

/// The bounded route → execute → continue loop (design D7), pure Core, owns no UI. It drives an injected
/// `LLMRuntime` (the batched conformer in production, `StubLLMRuntime` in tests), routes via
/// `structured()`, dispatches through the `ToolRegistry`, and is bounded by a hard step cap plus two
/// loop-guards. The running plan rides the existing `.thinking` channel via `onThinking`; the committed
/// answer is `.response`-channel only.
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
    /// The session this loop advances — audited + park-state-keyed by `ai-background-autonomy`. Defaults
    /// to a fresh id for the foreground one-shot loop.
    let sessionID: AgentSessionID
    /// Optional background-policy runner (`ai-background-autonomy`, 6.1–6.4): when present, each tool step
    /// routes through it (whitelist-aware tier → `BackgroundGate` decision → run/escalate/wait + audit)
    /// instead of calling `registry.run` directly. nil = the plain foreground path (existing behavior).
    let backgroundRunner: BackgroundToolRunner?

    init(runtime: LLMRuntime, registry: ToolRegistry, candidateSource: ToolCandidateSource,
         gate: ApprovalGate, reasoning: Bool = false, maxToolSteps: Int = 8,
         source: TaskSource = TaskSource(), onThinking: @escaping @Sendable (String) -> Void = { _ in },
         sessionID: AgentSessionID = AgentSessionID(), backgroundRunner: BackgroundToolRunner? = nil) {
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
    }

    func run(context initial: RouteContext) async -> AgentLoopResult {
        var context = initial
        var steps: [ToolStepResult] = []
        var lastRoute: ToolRoute?
        var candidateLimit = 5
        var declineCount: [String: Int] = [:]

        for _ in 0 ..< max(1, maxToolSteps) {
            if Task.isCancelled { return AgentLoopResult(outcome: .stopped(reason: .cancelled, text: ""), steps: steps) }

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
                // Background-autonomy path (6.1–6.4): when a runner is injected, each step routes through
                // it (whitelist-aware tier → BackgroundGate → run/escalate/wait + audit); otherwise the
                // plain foreground run is unchanged.
                let result: ToolStepResult
                if let runner = backgroundRunner {
                    result = await runner.run(call, sessionID: sessionID, registry: registry, gate: gate)
                } else {
                    result = await registry.run(call, gate: gate)
                }
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
                case .done, .awaitingApproval:
                    continue   // .awaitingApproval is resolved inside the contributor's gate await
                }
            }
        }
        // The hard cap is the backstop regardless of progress.
        return await answer(context, steps: steps, terminator: .cap)
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
                case .response: text += token.text
                case .thinking: onThinking(token.text)
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
