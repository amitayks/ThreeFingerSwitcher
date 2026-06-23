import Foundation

/// The Hub cost surface model (design D5, house requirement — never silent OOM). Given the chosen context
/// preset/tokens + the compact-KV toggle + the selected model's weight size & max context, it derives —
/// from the SAME pure `ConcurrencyBudget`/`KVCacheCost` the batched conformer uses — the estimated resident
/// RAM, the concurrent-stream count (so the user sees how many BACKGROUND sessions a context affords), and
/// a relative speed note. Pure + MLX-free (the live free-memory probe is `ProcessInfo.physicalMemory`,
/// available in Core) so it is `swift test`-buildable and tracks the preset/toggle live.
///
/// The KV constants mirror `BatchedGemmaMLXRuntime.currentBudget` (representative Gemma-class numbers) so
/// the Hub's displayed RAM/stream count agrees with what the conformer actually computes for K.
struct AgentContextCostModel {
    /// The resolved context budget (clamped to the model max), the compact-KV toggle, and the model.
    let contextTokens: Int
    let compactKV: Bool
    let weightBytes: Int64
    /// Injected so the math is unit-testable with a fixed memory size (defaults to the live probe).
    let unifiedMemoryBytes: Int64

    init(contextTokens: Int, compactKV: Bool, weightBytes: Int64,
         unifiedMemoryBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)) {
        self.contextTokens = max(1, contextTokens)
        self.compactKV = compactKV
        self.weightBytes = weightBytes
        self.unifiedMemoryBytes = unifiedMemoryBytes
    }

    /// The pure budget, built with the same KV cost model the GemmaRuntime conformer uses.
    var budget: ConcurrencyBudget {
        let bf16PerTokenPerLayer = 2_048.0
        let perTokenPerLayer = compactKV ? bf16PerTokenPerLayer / 2 : bf16PerTokenPerLayer
        let kv = KVCacheCost(slidingLayers: 40, globalLayers: 8, slidingWindow: 1_024,
                             kvBytesPerTokenPerLayer: perTokenPerLayer)
        return ConcurrencyBudget(unifiedMemoryBytes: unifiedMemoryBytes,
                                 weightBytes: weightBytes,
                                 reservedBytes: 6 * 1_000_000_000,
                                 kv: kv)
    }

    /// K — total concurrent streams that fit at this context (≥ 1, foreground always fits).
    var maxStreams: Int { budget.maxStreams(contextTokens: contextTokens) }

    /// Background sessions afforded beyond the foreground slot (0 when only the foreground fits).
    var backgroundStreams: Int { max(0, maxStreams - 1) }

    /// Estimated resident RAM at this (K, context) for the cost surface.
    var estimatedRAMBytes: Int64 { budget.estimatedRAM(streams: maxStreams, contextTokens: contextTokens) }

    /// A human "~NN GB" string for the estimated RAM (one decimal below 100 GB).
    var ramText: String {
        let gb = Double(estimatedRAMBytes) / 1_000_000_000
        return gb >= 100 ? String(format: "~%.0f GB", gb) : String(format: "~%.1f GB", gb)
    }

    /// "3 background sessions" / "1 background session" / "no background sessions" (honest at K=1).
    var backgroundText: String {
        switch backgroundStreams {
        case 0: return "no background sessions"
        case 1: return "1 background session"
        default: return "\(backgroundStreams) background sessions"
        }
    }

    /// A relative speed note — longer context = slower per token (design D5). Buckets by context size.
    var speedNote: String {
        switch contextTokens {
        case ..<12_000:  return "fastest per-token speed"
        case ..<40_000:  return "moderate per-token speed"
        default:         return "slower per-token speed"
        }
    }

    /// The single-line cost summary the Hub shows, updating live with the preset/toggle. e.g.
    /// "~24.0 GB · 3 background sessions · moderate per-token speed".
    var summary: String {
        "\(ramText) · \(backgroundText) · \(speedNote)"
    }
}
