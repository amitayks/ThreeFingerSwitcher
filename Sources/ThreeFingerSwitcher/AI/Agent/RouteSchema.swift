import Foundation

/// The fixed route schema + the route-prompt builder (design D1). The router uses the EXISTING
/// `structured()` seam against this single `StructuredSchema` — the reliability mechanism is
/// `structured()`'s repair/retry/decline, never native function-call tokens.
enum RouteSchema {

    /// The decision shape the model fills: a chosen `tool` (or "" to answer directly), its
    /// `argumentsJSON`, and a one-sentence `rationale`. Only `tool` is required (a plain answer needs
    /// nothing else), mirroring `ParsedActions` schema style.
    static let schema = StructuredSchema(
        name: "tool_route",
        json: """
        {
          "type": "object",
          "required": ["tool"],
          "properties": {
            "tool": { "type": "string", "description": "the chosen tool name, or \\"\\" to answer directly" },
            "argumentsJSON": { "type": "string", "description": "JSON object of arguments for the chosen tool" },
            "rationale": { "type": "string", "description": "one short sentence: why this choice" }
          }
        }
        """)

    /// Build the route prompt: the conversation tail + the candidate descriptors (name, summary, args
    /// schema) + the instruction to choose one OR answer directly. Pure + deterministic.
    static func prompt(context: RouteContext, candidates: [ToolDescriptor]) -> String {
        let transcript = ChatTemplate.flatten(context.messages)
        let toolLines = candidates.map { d in
            "- \(d.name): \(d.summary)\n    args schema: \(d.argsSchema.json)"
        }.joined(separator: "\n")
        return """
        You are deciding whether to call a tool to help with the user's request, or to answer directly.

        Conversation so far:
        \(transcript)

        Available tools:
        \(toolLines)

        Choose EXACTLY ONE tool by its exact name and provide "argumentsJSON" (a JSON object matching that \
        tool's args schema), OR set "tool" to "" to answer the user directly without any tool. Always give \
        a one-sentence "rationale".
        """
    }
}
