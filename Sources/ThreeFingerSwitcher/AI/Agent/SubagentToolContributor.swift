import Foundation

/// Subagents as routable tools (`refactor-park-and-background-agents` / `ai-subagents`): each REGISTERED
/// `Subagent` template is exposed as a `subagent:<name>` tool the route loop can invoke. Running one
/// opens the template's FRESH conversation (its own system prompt + the routed input — none of the
/// orchestrator's history) and streams ONE prompt-only chat over the injected runtime; ONLY the final
/// text re-enters the orchestrator thread as the step's summary (the context-hygiene contract). The
/// sub-task runs WITHIN the orchestrator's in-flight turn — same task, same cancellation — and offers no
/// tools of its own, so there is structurally no recursion. MLX-free Core (tests drive a stub runtime).
struct SubagentToolContributor: ToolContributor {
    let templates: [Subagent]
    /// Resolves the runtime per invocation (app-side: `modelManager.runtime(requiring: [.text])`) so the
    /// contributor is built once at registry time but always runs on the CURRENT model.
    let runtimeProvider: @Sendable () async throws -> LLMRuntime

    init(templates: [Subagent], runtimeProvider: @escaping @Sendable () async throws -> LLMRuntime) {
        self.templates = templates
        self.runtimeProvider = runtimeProvider
    }

    func descriptors() -> [ToolDescriptor] { templates.map(\.toolDescriptor) }

    func canHandle(_ tool: String) -> Bool {
        templates.contains { $0.toolDescriptor.name == tool }
    }

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        guard let template = templates.first(where: { $0.toolDescriptor.name == call.descriptor.name }) else {
            return ToolStepResult(tool: call.descriptor.name,
                                  status: .failed(headline: "That tool isn't available."),
                                  summary: "Unknown subagent: \(call.descriptor.name).")
        }
        let fresh = template.freshConversation(input: Self.input(from: call))
        do {
            let runtime = try await runtimeProvider()
            var text = ""
            for try await token in runtime.chat(LLMChatRequest(messages: fresh.messages)) {
                if Task.isCancelled { return Self.cancelled(call) }
                if token.channel == .response { text += token.text }
            }
            if Task.isCancelled { return Self.cancelled(call) }
            let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolStepResult(tool: call.descriptor.name, status: .done,
                                  summary: summary.isEmpty ? "(no output)" : summary)
        } catch let error as RuntimeError where error == .cancelled {
            return Self.cancelled(call)
        } catch is CancellationError {
            return Self.cancelled(call)
        } catch {
            // A subagent failure is a clean failed step (one taxonomy, one translator) — never a
            // fabricated summary, never raw error text.
            return ToolStepResult(tool: call.descriptor.name,
                                  status: .failed(headline: AIError.message(for: error).headline),
                                  summary: "")
        }
    }

    /// The sub-task input: the routed `{"input": …}` argument, falling back to the orchestrator's
    /// latest user text when the model routed with empty arguments.
    private static func input(from call: RoutedCall) -> String {
        struct Args: Decodable { var input: String? }
        let parsed = call.route.argumentsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(Args.self, from: $0) }
        let input = parsed?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return input.isEmpty ? call.userText : input
    }

    /// A discarded turn cancels the subagent WITH it — the loop's cancel sentinel, never a failure.
    private static func cancelled(_ call: RoutedCall) -> ToolStepResult {
        ToolStepResult(tool: call.descriptor.name,
                       status: .declined(reason: TaskKindToolContributor.cancelledReason),
                       summary: "Cancelled.")
    }
}

extension Subagent {
    /// The built-in template set (v1): deliberately small, prompt-only, single-turn. The set is
    /// injectable at the contributor, so a skills-derived roster is a later drop-in.
    static let builtIns: [Subagent] = [
        Subagent(
            name: "summarize",
            systemPrompt: "You are a focused summarizer running as an isolated sub-task. Condense the "
                + "provided input to its essential points, preserving concrete facts, names, and numbers. "
                + "Reply with ONLY the summary — no preamble, no commentary.",
            maxTurns: 1),
        Subagent(
            name: "draft",
            systemPrompt: "You are a focused writing assistant running as an isolated sub-task. Compose "
                + "the text the brief asks for — complete and ready to use. Reply with ONLY the drafted "
                + "text — no preamble, no commentary.",
            maxTurns: 1),
    ]
}
