import Foundation

/// The load-bearing reuse (design D4): a thin adapter that turns the existing `TaskKind`s into routable
/// tools and bridges a routed call back into the UNCHANGED `TaskDispatcher.prepare`/`execute`. The model
/// only chooses the menu item (and pre-fills it); the kind's own `ParsedActions` schema stays the
/// authority — so `TaskDispatcher`/`ParsedActions`/`TaskSinks` are byte-unchanged.
struct TaskKindToolContributor: ToolContributor {
    let dispatcher: TaskDispatching
    let resolver: WritePolicyResolving
    /// The authored task kinds available as tools (with their bound config — never invented by the router).
    let kinds: [TaskKind]

    init(dispatcher: TaskDispatching, resolver: WritePolicyResolving = DescriptorWritePolicy(), kinds: [TaskKind]) {
        self.dispatcher = dispatcher
        self.resolver = resolver
        self.kinds = kinds
    }

    /// A sentinel decline reason the loop recognizes as "the user cancelled the whole canvas" (not a skip).
    static let cancelledReason = "__cancelled__"

    func descriptors() -> [ToolDescriptor] { kinds.map(Self.descriptor(for:)) }

    func canHandle(_ tool: String) -> Bool { kinds.contains { Self.name(for: $0) == tool } }

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        let toolName = call.descriptor.name
        guard let kind = kinds.first(where: { Self.name(for: $0) == toolName }) else {
            return ToolStepResult(tool: toolName, status: .failed(headline: "That tool isn't available."),
                                  summary: "Unknown tool: \(toolName).")
        }

        // Fold the route's argumentsJSON into the prompt the dispatcher consumes — the args are a HINT;
        // the kind's ParsedActions schema re-validates them (so the router's JSON never reaches a sink
        // unvalidated). Carry the user's content so the parse has its source text.
        let resolvedPrompt = Self.fold(userText: call.userText, argumentsJSON: call.route.argumentsJSON)
        let review = await dispatcher.prepare(kind, resolvedPrompt: resolvedPrompt, source: call.source,
                                              reasoning: false)

        switch review {
        case let .declined(reason):
            return ToolStepResult(tool: toolName, status: .declined(reason: reason), summary: reason)
        case let .unavailable(reason):
            return ToolStepResult(tool: toolName, status: .failed(headline: reason), summary: reason)
        case let .action(title, _, _):
            switch resolver.effectiveTier(for: call.descriptor) {
            case .auto:
                return await fire(review, tool: toolName, title: title)
            case .confirm, .dangerous:
                switch await gate.awaitDecision(for: review) {
                case .approve:
                    return await fire(review, tool: toolName, title: title)
                case .skip:
                    return ToolStepResult(tool: toolName, status: .declined(reason: "skipped"),
                                          summary: "Skipped “\(title)”.")
                case .cancel:
                    return ToolStepResult(tool: toolName, status: .declined(reason: Self.cancelledReason),
                                          summary: "Cancelled.")
                }
            }
        }
    }

    /// Execute a reviewed action; a sink that throws becomes `.failed` with a CLEAN headline — never a
    /// false "Done" (the executor's existing honesty rule).
    private func fire(_ review: TaskReview, tool: String, title: String) async -> ToolStepResult {
        do {
            try await dispatcher.execute(review)
            return ToolStepResult(tool: tool, status: .done, summary: "Done: \(title).")
        } catch {
            return ToolStepResult(tool: tool, status: .failed(headline: AIError.message(for: error).headline),
                                  summary: "Couldn't complete “\(title)”.")
        }
    }

    // MARK: - Descriptor identity (Decision Q2: config bound in the name)

    static func fold(userText: String, argumentsJSON: String) -> String {
        var parts: [String] = []
        if !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(userText) }
        if !argumentsJSON.isEmpty, argumentsJSON != "{}" {
            parts.append("Use these arguments where they fit: \(argumentsJSON)")
        }
        return parts.joined(separator: "\n\n")
    }

    static func name(for kind: TaskKind) -> String {
        switch kind {
        case .addToCalendar: return "add_to_calendar"
        case .addToReminder: return "add_to_reminder"
        case .newContact: return "new_contact"
        case let .saveToProject(project): return "save_to_project:\(project)"
        case let .openToolWithPayload(tool): return "open_tool:\(tool)"
        case let .sendTo(destination): return "send_to:\(destinationKey(destination))"
        }
    }

    static func destinationKey(_ destination: Destination) -> String {
        switch destination {
        case let .shortcut(name): return "shortcut:\(name)"
        case let .urlScheme(scheme): return "url:\(scheme)"
        case let .shell(command): return "shell:\(command)"
        }
    }

    static func descriptor(for kind: TaskKind) -> ToolDescriptor {
        ToolDescriptor(name: name(for: kind), summary: summary(for: kind),
                       argsSchema: StructuredSchema(name: name(for: kind), json: "{\"type\":\"object\"}"),
                       writePolicy: .confirm, keywords: keywords(for: kind))
    }

    static func summary(for kind: TaskKind) -> String {
        switch kind {
        case .addToCalendar: return "Create a calendar event from the request."
        case .addToReminder: return "Create a reminder / to-do from the request."
        case .newContact: return "Create a contact card from the request."
        case let .saveToProject(project): return "Append the content to the “\(project)” project note."
        case let .openToolWithPayload(tool): return "Generate a payload and open “\(tool)” with it."
        case let .sendTo(destination): return "Send the content to \(destinationKey(destination))."
        }
    }

    static func keywords(for kind: TaskKind) -> [String] {
        switch kind {
        case .addToCalendar: return ["calendar", "event", "meeting", "schedule", "appointment"]
        case .addToReminder: return ["reminder", "todo", "task", "remind"]
        case .newContact: return ["contact", "person", "card", "address"]
        case .saveToProject: return ["save", "note", "project", "append"]
        case .openToolWithPayload: return ["open", "tool", "payload"]
        case .sendTo: return ["send", "share", "route", "shortcut"]
        }
    }
}
