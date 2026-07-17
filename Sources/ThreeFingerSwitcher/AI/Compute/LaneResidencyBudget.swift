import Foundation

/// Cross-lane co-residency math (design D3). PURE: the live free-memory probe happens at the runtime
/// boundary and is INJECTED here (mirrors `ConcurrencyBudget`), so the decision is unit-testable without
/// Metal. It answers ONE question: does the small ternary model co-reside with the current GPU batch
/// (resident chat weights, read once) + the GPU streams' KV under the 48 GB unified-memory budget?
///
/// The ternary weights are ~32× smaller than an FP16/Q4 chat model's, so `ternaryResidencyBytes` is a
/// SMALL constant. The whole point: the ternary model fits in headroom where a SECOND full chat model
/// would not — that is what makes a second lane a co-resident win rather than an eviction.
///
/// This slice supplies ONLY the ternary co-residency MATH; the fleet's eviction policy itself is owned by
/// `ai-model-fleet` (§C1) and is out of scope here.
public struct LaneResidencyBudget: Equatable, Sendable {
    /// Resident GPU chat weights, read once and shared across all GPU streams (e.g. ~17 GB at 4-bit).
    public var chatWeightBytes: Int64
    /// Per-GPU-stream KV-cache bytes at the current context length (the cost that grows with concurrency).
    public var kvBytesPerGPUStream: Int64
    /// The ternary model's resident footprint — SMALL (~32× smaller weights). Read once; it does not grow
    /// per CPU-lane burst (the CPU lane's per-burst working set is negligible beside the weight set).
    public var ternaryResidencyBytes: Int64
    /// OS + app + graph-activation headroom held out of the budget.
    public var reservedBytes: Int64

    public init(chatWeightBytes: Int64,
                kvBytesPerGPUStream: Int64,
                ternaryResidencyBytes: Int64,
                reservedBytes: Int64) {
        self.chatWeightBytes = chatWeightBytes
        self.kvBytesPerGPUStream = kvBytesPerGPUStream
        self.ternaryResidencyBytes = ternaryResidencyBytes
        self.reservedBytes = reservedBytes
    }

    /// Bytes the resident GPU batch occupies at `gpuStreams` streams (weights read once + KV per stream).
    public func gpuResidentBytes(gpuStreams: Int) -> Int64 {
        chatWeightBytes + Int64(max(0, gpuStreams)) * kvBytesPerGPUStream
    }

    /// Does the ternary model co-reside with the current GPU batch + KV under `freeBytes`?
    ///
    /// `freeBytes` is the total unified memory available to the AI feature (injected). The ternary model
    /// is admitted iff, after the GPU batch's resident bytes and the reserved headroom, the small ternary
    /// footprint still fits. `contextTokens` is accepted for signature parity with the fleet's call site
    /// (the GPU per-stream KV already encodes the context cost in `kvBytesPerGPUStream`); it is not used
    /// to grow the ternary footprint, which is context-independent here.
    public func ternaryCoResides(freeBytes: Int64, gpuStreams: Int, contextTokens: Int) -> Bool {
        _ = contextTokens
        let remaining = freeBytes - gpuResidentBytes(gpuStreams: gpuStreams) - reservedBytes
        return remaining >= ternaryResidencyBytes
    }
}
