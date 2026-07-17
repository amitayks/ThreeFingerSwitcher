import Foundation

/// A deterministic, scriptable CPU-ternary-lane `LLMRuntime` for `swift build` / `swift test` (the real
/// bitnet.cpp-class `TernaryCPURuntime` is native-linked and `xcodebuild` compile-verify only — see the
/// GemmaRuntime file). It conforms to the EXISTING `LLMRuntime` seam (design D2: a SECOND conformer,
/// NOT a new protocol), so feature code stays model-agnostic and selects the CPU lane BY LANE.
///
/// It scripts the SHORT-BURST paths the CPU lane actually serves (design D5): a `structured()` route
/// turn, classify, memory-retrieval, and parked-subagent `generate`/`chat` — never the long foreground
/// reply (that is GPU-only). A scripted error fails the burst so the per-turn `.failed` path is
/// observable; a cancelled burst is NOT a failure (`RuntimeError.cancelled`, treated as benign upstream).
///
/// `capabilities` advertises `.text` ONLY — a ternary text model carries no vision/audio, and the policy
/// keeps `mediaDiffusion`/vision roles on the GPU lane, so a vision request against this stub is a hard
/// `unsupportedModality` error (never a silent degrade).
public final class StubTernaryRuntime: LLMRuntime, @unchecked Sendable {

    /// CPU ternary lane carries TEXT only. A vision/media role is never routed here (the role→lane policy
    /// keeps `mediaDiffusion` on `.gpu`); a vision request still hard-errors rather than degrading.
    public let capabilities: Set<Modality>

    /// Scripted response chunks for `generate`/`chat`. Empty → echo the prompt as one token.
    private var scriptedTokens: [String]
    /// Scripted `structured(...)` behavior. nil → a generic empty-object attempt.
    private var structuredScript: StubLLMRuntime.StructuredScript?
    /// A scripted load/prepare/decode failure for the next burst (simulates a CPU-lane failure mapped
    /// into `RuntimeError` at the conformer boundary). Cleared after it fires once.
    private var scriptedError: RuntimeError?
    private var maxRepairAttempts: Int
    private let interTokenDelayNanos: UInt64
    private let lock = NSLock()

    public init(capabilities: Set<Modality> = [.text],
                scriptedTokens: [String] = [],
                structuredScript: StubLLMRuntime.StructuredScript? = nil,
                scriptedError: RuntimeError? = nil,
                maxRepairAttempts: Int = 3,
                interTokenDelayNanos: UInt64 = 1_000_000) {
        self.capabilities = capabilities
        self.scriptedTokens = scriptedTokens
        self.structuredScript = structuredScript
        self.scriptedError = scriptedError
        self.maxRepairAttempts = maxRepairAttempts
        self.interTokenDelayNanos = interTokenDelayNanos
    }

    // MARK: Streaming (short bursts only — never the long reply)

    public func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
        let chunks = scriptedTokens.isEmpty ? [request.prompt] : scriptedTokens
        let delay = interTokenDelayNanos
        let needsVision = request.requiresVision
        let caps = capabilities
        let err = takeError()

        return AsyncThrowingStream { continuation in
            let task = Task {
                // A vision request against a text-only ternary lane is a hard error, never a degrade.
                if needsVision && !caps.contains(.vision) {
                    continuation.finish(throwing: RuntimeError.unsupportedModality(.vision))
                    return
                }
                // A simulated CPU-lane failure (load/prepare/decode), already mapped to RuntimeError.
                if let err {
                    continuation.finish(throwing: err)
                    return
                }
                do {
                    for (i, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                        try Task.checkCancellation()
                        continuation.yield(Token(chunk, isFinal: i == chunks.count - 1))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // Cancellation is NOT a failure (the turn was discarded); a clean benign terminal.
                    continuation.finish(throwing: RuntimeError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Structured (the router's route turn — the CPU lane's bread and butter)

    public func structured<T: Decodable & Sendable>(
        _ request: LLMRequest,
        schema: StructuredSchema,
        as type: T.Type
    ) async throws -> StructuredOutcome<T> {
        try Task.checkCancellation()
        if let err = takeError() { throw err }
        // Reuse the stub's proven validate → repair/retry → decode/decline pipeline so the CPU-lane
        // route path exercises the SAME contract the GPU runtime does (no shortcut).
        let proxy = StubLLMRuntime(capabilities: capabilities,
                                   structuredScript: structuredScript,
                                   maxRepairAttempts: maxRepairAttempts)
        return try await proxy.structured(request, schema: schema, as: type)
    }

    private func takeError() -> RuntimeError? {
        lock.lock(); defer { lock.unlock() }
        let e = scriptedError
        scriptedError = nil
        return e
    }
}
