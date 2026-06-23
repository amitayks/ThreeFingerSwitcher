import Foundation

/// The Core, model-agnostic message-list→prompt assembler (design D3). The default `LLMRuntime.chat(_:)`
/// needs *a* prompt from a message list; this produces a deterministic, role-labeled transcript.
///
/// Reads `message.text` ONLY — never `thinking` — so the default conversation path cannot leak reasoning
/// into the prompt (the load-bearing invariant of `AgentMessage`).
///
/// FLAGGED: GemmaRuntime — the REAL model-specific chat template (Gemma's `<start_of_turn>` turn markers
/// and the `enable_thinking` reasoning flag) is owned by the on-device Gemma conformer in the
/// `ai-batched-runtime-and-context` / GemmaRuntime slice, which OVERRIDES `chat(_:)` to build the native
/// template instead of calling `flatten`. This Core assembler is the model-agnostic default + the basis
/// for deterministic tests; it is intentionally NOT Gemma's real template.
public enum ChatTemplate {

    /// Build a deterministic, role-labeled transcript from `messages`, reading committed `text` only.
    /// A `.tool` message renders its `toolResult?.summary` (the outcome fed back into the loop). A
    /// trailing `Assistant:` cue invites the next turn. An empty list yields the cue alone.
    public static func flatten(_ messages: [AgentMessage]) -> String {
        let lines: [String] = messages.map { message in
            switch message.role {
            case .system:    return "System: \(message.text)"
            case .user:      return "User: \(message.text)"
            case .assistant: return "Assistant: \(message.text)"
            case .tool:      return "Tool: \(message.toolResult?.summary ?? message.text)"
            }
        }
        guard !lines.isEmpty else { return assistantCue }
        return lines.joined(separator: "\n\n") + "\n\n" + assistantCue
    }

    /// The trailing cue that invites the model to produce the next assistant turn.
    static let assistantCue = "Assistant:"
}
