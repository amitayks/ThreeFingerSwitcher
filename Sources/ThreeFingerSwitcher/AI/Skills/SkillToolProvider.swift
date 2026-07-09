import Foundation

/// Projects skills into routable tools and invokes them — the skill↔router contract (design D3). It is a
/// `ToolContributor` that `ai-tool-routing`'s `ToolRegistry` aggregates alongside the task tools, memory
/// tools, and `launch_claude`. THIS slice provides the contributor; the route→execute→continue loop is
/// owned by `ai-tool-routing`. MLX-free Core.
struct SkillToolProvider: ToolContributor {
    let manifests: [SkillManifest]
    let runtime: LLMRuntime
    let dispatcher: TaskDispatching
    let resolver: WritePolicyResolving
    /// Whether the model reasons (global default) — per-skill `.on`/`.off` still wins via the command.
    let globalReasoning: Bool

    init(manifests: [SkillManifest], runtime: LLMRuntime, dispatcher: TaskDispatching,
         resolver: WritePolicyResolving = DescriptorWritePolicy(), globalReasoning: Bool = false) {
        self.manifests = manifests
        self.runtime = runtime
        self.dispatcher = dispatcher
        self.resolver = resolver
        self.globalReasoning = globalReasoning
    }

    func descriptors() -> [ToolDescriptor] { manifests.map(Self.descriptor(for:)) }

    func canHandle(_ tool: String) -> Bool { manifests.contains { $0.id == tool } }

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        let toolName = call.descriptor.name
        guard let m = manifests.first(where: { $0.id == toolName }) else {
            return ToolStepResult(tool: toolName, status: .failed(headline: "That skill isn't available."),
                                  summary: "Unknown skill: \(toolName).")
        }
        let context = FireContext(inputText: call.userText)
        let prompt = PromptTemplate.resolve(m.command.promptTemplate, with: context, activeLanguage: nil)
        let reasoning = m.command.resolvedReasoning(globalDefault: globalReasoning)

        // In-place skill: generate the text result; that text IS the step's outcome.
        if let kind = Self.taskKind(for: m.command) {
            return await runSideEffecting(kind, m: m, prompt: prompt, reasoning: reasoning,
                                          descriptor: call.descriptor, gate: gate)
        }
        do {
            let text = try await runtime.generateText(
                LLMRequest(prompt: prompt, image: nil, reasoning: reasoning))
            return ToolStepResult(tool: toolName, status: .done, summary: text)
        } catch {
            return ToolStepResult(tool: toolName, status: .failed(headline: AIError.message(for: error).headline),
                                  summary: "Couldn't run “\(m.title)”.")
        }
    }

    /// A side-effecting skill bridges into the UNCHANGED `TaskDispatching.prepare`/`execute`, gated by the
    /// descriptor's write policy (mirrors `TaskKindToolContributor`).
    private func runSideEffecting(_ kind: TaskKind, m: SkillManifest, prompt: String, reasoning: Bool,
                                  descriptor: ToolDescriptor, gate: ApprovalGate) async -> ToolStepResult {
        let review = await dispatcher.prepare(kind, resolvedPrompt: prompt, source: TaskSource(), reasoning: reasoning)
        switch review {
        case let .declined(reason):
            return ToolStepResult(tool: m.id, status: .declined(reason: reason), summary: reason)
        case let .unavailable(reason):
            return ToolStepResult(tool: m.id, status: .failed(headline: reason), summary: reason)
        case let .action(title, _, _):
            switch resolver.effectiveTier(for: descriptor) {
            case .auto:
                return await fire(review, tool: m.id, title: title)
            case .confirm, .dangerous:
                switch await gate.awaitDecision(for: review) {
                case .approve: return await fire(review, tool: m.id, title: title)
                case .skip: return ToolStepResult(tool: m.id, status: .declined(reason: "skipped"),
                                                  summary: "Skipped “\(title)”.")
                case .cancel: return ToolStepResult(tool: m.id,
                                                    status: .declined(reason: TaskKindToolContributor.cancelledReason),
                                                    summary: "Cancelled.")
                }
            }
        }
    }

    private func fire(_ review: TaskReview, tool: String, title: String) async -> ToolStepResult {
        do {
            try await dispatcher.execute(review)
            return ToolStepResult(tool: tool, status: .done, summary: "Done: \(title).")
        } catch {
            return ToolStepResult(tool: tool, status: .failed(headline: AIError.message(for: error).headline),
                                  summary: "Couldn't complete “\(title)”.")
        }
    }

    // MARK: - Projection

    static func descriptor(for m: SkillManifest) -> ToolDescriptor {
        ToolDescriptor(
            name: m.id,
            summary: m.summary,
            argsSchema: schema(for: m.command),
            writePolicy: m.command.confirmBeforeRun ? .confirm : .auto,
            keywords: m.keywords)
    }

    /// The args schema the router targets: the bound `ParsedActions` schema for a side-effecting sink (so
    /// the model emits the same validated/declinable shape the dispatcher consumes); a minimal text schema
    /// for an in-place sink (the model just produces text).
    static func schema(for command: AICommand) -> StructuredSchema {
        switch command.sideEffect {
        case .runTask(.addToCalendar): return ParsedCalendarEvent.schema
        case .runTask(.addToReminder): return ParsedReminder.schema
        case .runTask(.newContact): return ParsedContact.schema
        case .runTask(.saveToProject): return ParsedSaveToProject.schema
        case .runTask(.openToolWithPayload): return ParsedOpenTool.schema
        case .runTask(.sendTo), .sendTo: return ParsedSendTo.schema
        default:   // in-place (no side-effecting output): the model just produces text
            return StructuredSchema(name: "text_result",
                                    json: "{\"type\":\"object\",\"required\":[\"result\"],\"properties\":{\"result\":{\"type\":\"string\"}}}")
        }
    }

    /// The `TaskKind` this command's side-effecting output routes to (reads `command.sideEffect`), or nil
    /// for an in-place skill.
    private static func taskKind(for command: AICommand) -> TaskKind? {
        switch command.sideEffect {
        case let .runTask(kind): return kind
        case let .sendTo(destination): return .sendTo(destination)
        default: return nil
        }
    }
}
