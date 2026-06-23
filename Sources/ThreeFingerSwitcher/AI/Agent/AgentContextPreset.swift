import Foundation

/// The user-facing context-size preset (design D5). Three comprehensible presets plus `custom`; the
/// resolved token budget is always clamped to the model's `maxContextTokens`. Longer context trades
/// concurrency (fewer background streams) and per-token speed for recall — the Hub surfaces that cost.
public enum AgentContextPreset: String, Codable, Sendable, CaseIterable {
    case balanced   // a comfortable mid value — the default
    case long
    case max        // the model's architectural maximum
    case custom     // an explicit `agentContextTokens` value

    /// The token budget this preset resolves to, clamped to the model max. `custom` uses the explicit
    /// stored value.
    public func tokens(modelMax: Int, custom: Int) -> Int {
        // `max`/`min` are qualified — inside this enum body the bare names resolve to the `.max` case.
        let clamped: (Int) -> Int = { Swift.min(Swift.max(1, $0), Swift.max(1, modelMax)) }
        switch self {
        case .balanced: return clamped(8_192)
        case .long: return clamped(32_768)
        case .max: return Swift.max(1, modelMax)
        case .custom: return clamped(custom)
        }
    }

    /// A short human label for the Hub segmented control.
    public var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .long: return "Long"
        case .max: return "Max"
        case .custom: return "Custom"
        }
    }
}
