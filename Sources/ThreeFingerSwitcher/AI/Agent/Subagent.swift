import Foundation

/// A fixed-pattern context-hygiene primitive (design D7) — NOT concurrency, NOT dynamic spawning. A
/// subagent runs a bounded sub-task in a FRESH `AgentConversation` (empty history, its own system prompt)
/// and returns only a SUMMARY to the orchestrator, so the orchestrator's context never absorbs the
/// sub-task's intermediate turns. This is the honest justification for "subagents" on a single-GPU
/// machine: they are context hygiene (a lean orchestrator), not parallelism.
///
/// It is a NAMED, bounded template from a small registered set — there is deliberately NO open-ended,
/// model-decided recursive spawning (a small model orchestrates unbounded recursion poorly). A subagent
/// may itself be a routed tool step (`ai-tool-routing`); the loop appends only the returned summary.
struct Subagent: Equatable, Sendable {
    let name: String            // a named, fixed template (not model-invented)
    let systemPrompt: String
    let maxTurns: Int           // bounded

    init(name: String, systemPrompt: String, maxTurns: Int = 4) {
        self.name = name
        self.systemPrompt = systemPrompt
        self.maxTurns = max(1, maxTurns)
    }

    /// Open the subagent's FRESH conversation seeded with its system prompt + the orchestrator's input —
    /// a brand-new `AgentSessionID`, empty of the orchestrator's history. (The actual turn loop runs on
    /// the injected runtime; this models the isolation contract.)
    func freshConversation(input: String, now: Date = Date()) -> AgentConversation {
        AgentConversation(
            id: AgentSessionID(),
            title: name,
            messages: [
                AgentMessage(role: .system, text: systemPrompt, createdAt: now),
                AgentMessage(role: .user, text: input, createdAt: now),
            ],
            createdAt: now, updatedAt: now,
            skillID: name)
    }
}

/// What a subagent returns to the orchestrator: ONLY a summary (never the raw intermediate turns) plus
/// its session id (so it can ride a batch slot like any other stream — concurrency-cheap + context-cheap).
struct SubagentResult: Equatable, Sendable {
    let summary: String
    let sessionID: AgentSessionID
}

extension Subagent {
    /// Expose "run subagent <name>" as a routable tool (design D7 / blueprint §3.4): `ai-tool-routing`
    /// registers this so the model can invoke the subagent as one routed step, and only the returned
    /// summary re-enters the orchestrator's thread as a `.tool` message. Read-only to the orchestrator's
    /// world (`.auto`) — the subagent's own steps are gated within its fresh session.
    var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: "subagent:\(name)",
            summary: "Run the \(name) sub-task in a fresh context and return only its summary.",
            argsSchema: StructuredSchema(name: "subagent_\(name)", json: "{\"type\":\"object\",\"properties\":{\"input\":{\"type\":\"string\"}}}"),
            writePolicy: .auto,
            keywords: ["subagent", name])
    }
}
