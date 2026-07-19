import Foundation

/// The notch chat's ONE tuning dial (`notch-timeline-and-tuning`, design D6): four ordered stops over
/// (reasoning, context) that the in-notch settings zone's slider scrubs. Deliberately notch-specific —
/// the Hub's global `aiReasoningEnabled` / `agentContextPreset` keep steering the launcher band and the
/// other agent surfaces; this dial shapes only conversations BORN at the notch (snapshot at birth,
/// carried for life — see `AgentConversation.reasoningOverride` / `.contextTokens`).
///
/// Context values reuse `AgentContextPreset`'s resolution (Balanced 8k / Long 32k / model max) so the
/// two surfaces can never disagree about what a stop means in tokens.
public enum NotchTuning: String, Codable, Sendable, CaseIterable {
    /// Thinking off · base context — the fastest first token, no reasoning latency.
    case quick
    /// Thinking on · base context — the default (matches the app-wide defaults).
    case balanced
    /// Thinking on · long context.
    case deep
    /// Thinking on · the model's architectural maximum context.
    case max

    /// Whether conversations born under this stop reason before answering.
    public var reasoning: Bool { self != .quick }

    /// The context-token budget this stop resolves to, clamped to the model max (the
    /// `AgentContextPreset` resolution, so a stop and a Hub preset with the same name mean the same
    /// number of tokens).
    public func contextTokens(modelMax: Int) -> Int {
        switch self {
        case .quick, .balanced: return AgentContextPreset.balanced.tokens(modelMax: modelMax, custom: 0)
        case .deep: return AgentContextPreset.long.tokens(modelMax: modelMax, custom: 0)
        case .max: return AgentContextPreset.max.tokens(modelMax: modelMax, custom: 0)
        }
    }

    /// A short human label for the slider stop.
    public var title: String {
        switch self {
        case .quick: return "Quick"
        case .balanced: return "Balanced"
        case .deep: return "Deep"
        case .max: return "Max"
        }
    }

    /// This stop's position on the discrete slider (0…count-1, in declaration order).
    public var sliderIndex: Int { Self.allCases.firstIndex(of: self) ?? 1 }

    /// The stop for a slider position, clamped into range (a fractional slider value rounds to the
    /// nearest stop).
    public static func fromSliderIndex(_ index: Int) -> NotchTuning {
        let all = Self.allCases
        return all[Swift.min(Swift.max(index, 0), all.count - 1)]
    }
}
