import Foundation

/// The voice-side tools (`add-voice-computer-use-agent`, design D6/D7): `speak` (.auto — the agent
/// narrates on demand and the loop uses it for progress) and the auto-mode pair —
/// `enable_auto_mode` (.confirm: the ONE approval that can't be skipped) / `disable_auto_mode`
/// (.auto: revocation is instant). Two descriptors instead of one boolean tool so the tier is
/// honest per direction.
struct VoiceToolContributor: ToolContributor {

    /// Live voice opt-in (speak is absent when voice is off; auto-mode tools ride the computer-use flag).
    let voiceEnabled: @Sendable () -> Bool
    let computerUseEnabled: @Sendable () -> Bool
    /// Speak through the synthesizer seam (main-actor).
    let speak: @MainActor (String) -> Void
    /// Flip the CURRENT conversation's auto-approve grant (main-actor; wired per-engine).
    let setAutoMode: @MainActor (Bool) -> Void

    static let speakName = "speak"
    static let enableAutoName = "enable_auto_mode"
    static let disableAutoName = "disable_auto_mode"

    func descriptors() -> [ToolDescriptor] {
        var out: [ToolDescriptor] = []
        if voiceEnabled() {
            out.append(ToolDescriptor(
                name: Self.speakName,
                summary: "Say a short message aloud to the user.",
                argsSchema: StructuredSchema(name: Self.speakName,
                                             json: #"{"type":"object","required":["text"],"properties":{"text":{"type":"string"}}}"#),
                writePolicy: .auto,
                keywords: ["speak", "say", "read", "aloud", "voice", "tell"]))
        }
        if computerUseEnabled() {
            out.append(ToolDescriptor(
                name: Self.enableAutoName,
                summary: "Turn ON auto mode for this conversation: acts run without per-step approval (narrated).",
                argsSchema: StructuredSchema(name: Self.enableAutoName, json: #"{"type":"object"}"#),
                writePolicy: .confirm,
                keywords: ["auto", "mode", "without asking", "automatically", "hands-free", "don't ask"]))
            out.append(ToolDescriptor(
                name: Self.disableAutoName,
                summary: "Turn OFF auto mode for this conversation (acts need approval again).",
                argsSchema: StructuredSchema(name: Self.disableAutoName, json: #"{"type":"object"}"#),
                writePolicy: .auto,
                keywords: ["auto", "mode", "off", "stop", "ask", "approval"]))
        }
        return out
    }

    func canHandle(_ tool: String) -> Bool {
        [Self.speakName, Self.enableAutoName, Self.disableAutoName].contains(tool)
    }

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        switch call.descriptor.name {
        case Self.speakName:
            guard voiceEnabled() else {
                return ToolStepResult(tool: call.descriptor.name,
                                      status: .failed(headline: "Voice is turned off."),
                                      summary: "Voice is turned off.")
            }
            let text = Self.textArgument(from: call.route.argumentsJSON) ?? call.userText
            guard !text.isEmpty else {
                return ToolStepResult(tool: Self.speakName,
                                      status: .failed(headline: "There's nothing to say."),
                                      summary: "speak needs text.")
            }
            await MainActor.run { speak(text) }
            return ToolStepResult(tool: Self.speakName, status: .done,
                                  summary: "Spoke: \(String(text.prefix(120)))")

        case Self.enableAutoName:
            // The one grant that ALWAYS gates (spec: "Granting auto mode is itself gated").
            let review = TaskReview.action(
                title: "Enable auto mode",
                fields: [ReviewField("Scope", "this conversation"),
                         ReviewField("Effect", "clicks/typing run without per-step approval (narrated)")],
                payload: .openTool(tool: Self.enableAutoName,
                                   action: ParsedOpenTool(applicable: true, reason: nil, payload: "on")))
            switch await gate.awaitDecision(for: review) {
            case .approve:
                await MainActor.run { setAutoMode(true) }
                return ToolStepResult(tool: Self.enableAutoName, status: .done,
                                      summary: "Auto mode is ON for this conversation.")
            case .skip:
                return ToolStepResult(tool: Self.enableAutoName, status: .declined(reason: "skipped"),
                                      summary: "Auto mode stays off.")
            case .cancel:
                return ToolStepResult(tool: Self.enableAutoName,
                                      status: .declined(reason: TaskKindToolContributor.cancelledReason),
                                      summary: "Cancelled.")
            }

        case Self.disableAutoName:
            await MainActor.run { setAutoMode(false) }   // instant revoke, no gate
            return ToolStepResult(tool: Self.disableAutoName, status: .done,
                                  summary: "Auto mode is OFF.")

        default:
            return ToolStepResult(tool: call.descriptor.name,
                                  status: .failed(headline: "That tool isn't available."),
                                  summary: "Unknown tool: \(call.descriptor.name).")
        }
    }

    static func textArgument(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
