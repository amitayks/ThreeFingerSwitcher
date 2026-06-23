import Foundation

/// The per-stream KV-cache cost model (design D3/D4). Gemma 4 interleaves **local sliding-window** layers
/// (most layers; their KV is bounded by the window) with a few **global** layers (full-context KV), so
/// per-token KV bytes are NOT uniform across layers — treating every layer as global over-estimates KV
/// and needlessly throttles concurrency; treating every layer as local under-estimates and risks OOM.
/// Pure value type (no MLX) so it is unit-testable with fixed inputs. `public` so the GemmaRuntime
/// conformer can build it from the live model config.
public struct KVCacheCost: Equatable, Sendable {
    public var slidingLayers: Int
    public var globalLayers: Int
    public var slidingWindow: Int            // tokens the sliding-window layers retain
    public var kvBytesPerTokenPerLayer: Double   // a function of head dim × num-kv-heads × kv-quant bits

    public init(slidingLayers: Int, globalLayers: Int, slidingWindow: Int, kvBytesPerTokenPerLayer: Double) {
        self.slidingLayers = slidingLayers
        self.globalLayers = globalLayers
        self.slidingWindow = slidingWindow
        self.kvBytesPerTokenPerLayer = kvBytesPerTokenPerLayer
    }

    /// The interleaved-attention KV byte sum for a context length: sliding layers retain at most
    /// `slidingWindow` tokens each; global layers retain the full context.
    public func kvBytes(forContext ctx: Int) -> Int64 {
        let perToken = kvBytesPerTokenPerLayer
        let slidingTokens = Double(slidingLayers) * Double(min(max(0, ctx), slidingWindow))
        let globalTokens = Double(globalLayers) * Double(max(0, ctx))
        return Int64((slidingTokens + globalTokens) * perToken)
    }
}

/// RAM-is-the-ceiling concurrency math (design D4). Pure: the live free-memory probe happens at the
/// GemmaRuntime boundary and is INJECTED here, so the math is unit-testable without Metal.
public struct ConcurrencyBudget: Equatable, Sendable {
    public var unifiedMemoryBytes: Int64    // total unified memory (probed + injected)
    public var weightBytes: Int64           // resident weights, read once (shared across all streams)
    public var reservedBytes: Int64         // OS + app + graph-activation headroom
    public var kv: KVCacheCost

    public init(unifiedMemoryBytes: Int64, weightBytes: Int64, reservedBytes: Int64, kv: KVCacheCost) {
        self.unifiedMemoryBytes = unifiedMemoryBytes
        self.weightBytes = weightBytes
        self.reservedBytes = reservedBytes
        self.kv = kv
    }

    /// How many concurrent streams fit at this context length. CLAMPED ≥ 1 — the foreground session
    /// always fits even if a chosen context is so large only one stream is affordable (then background
    /// sessions wait; never an OOM). This is the honest "growing context trades concurrency for length."
    public func maxStreams(contextTokens: Int) -> Int {
        let perStream = kv.kvBytes(forContext: contextTokens)
        guard perStream > 0 else { return 1 }
        let free = unifiedMemoryBytes - weightBytes - reservedBytes
        guard free > 0 else { return 1 }
        return max(1, Int(free / perStream))
    }

    /// Estimated resident RAM at a given (streams, context) — for the Hub cost surface (never silent OOM).
    public func estimatedRAM(streams: Int, contextTokens: Int) -> Int64 {
        weightBytes + reservedBytes + Int64(max(1, streams)) * kv.kvBytes(forContext: contextTokens)
    }
}
