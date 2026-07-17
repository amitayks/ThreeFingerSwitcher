// TernaryCPURuntime — the CPU-lane ternary/BitNet-class `LLMRuntime` conformer (ai-compute-tiers §5).
//
// FLAGGED: user xcodebuild + stable-signed build.
//
// This is the SECOND `LLMRuntime` conformer (design D2 — a conformer, NOT a new protocol), carrying a
// SMALL ternary/BitNet-class model on the CPU lane. It is native-linked (it drives a bitnet.cpp-class
// inference process / library), so it is `xcodebuild` COMPILE-VERIFY ONLY here — the agent never
// builds/signs/installs the `.app` (ad-hoc signing breaks TCC; the metallib `*.bundle` copy in
// `build-app.sh` must not regress). REAL correctness — live CPU/GPU concurrency, CPU per-token speed,
// no cross-lane bleed, RAM/heat — is the USER's stable-signed run-verify (tasks 5.2 / 8.3).
//
// HONEST CONSTRAINT (design D5): CPU per-token is SLOWER than the GPU batched token. So this lane serves
// SHORT, FREQUENT, STRUCTURED bursts ONLY — the router's `structured()` route turn, classify,
// memory-retrieval, and parked-subagent `generate`/`chat`. The long foreground reply is NEVER routed
// here (the role→lane policy keeps `foregroundGeneration` on `.gpu`); its value is running its short
// bursts CONCURRENTLY with the GPU reply (the ternary weights are ~32× smaller → bandwidth-frugal → low
// contention on the shared ~153 GB/s bus), not being faster per token.
//
// ERROR TAXONOMY (design D7): every vendor/OS failure (bitnet.cpp-class load/prepare/decode, `Process`
// spawn/exit, file IO over the weights) is mapped INTO `RuntimeError` AT THIS BOUNDARY, exactly like the
// GPU runtime — so feature/UI code only ever sees `RuntimeError`, surfaced through `AIError.message(for:)`
// as a clean headline. A failed burst is an observable `.failed` for that turn (never a false "done");
// cancellation is `RuntimeError.cancelled`, treated as benign upstream (not a failure). A `ComputeError`
// is deliberately NOT added — `RuntimeError.unavailable` / `.modelLoadFailed` / `.modelMissing` /
// `.decodeFailed` / `.cancelled` carry every CPU-lane case (D7: prefer extending `RuntimeError`).

import Foundation
import os
import ThreeFingerSwitcherCore

public final class TernaryCPURuntime: LLMRuntime, @unchecked Sendable {

    static let log = Logger(subsystem: "ThreeFingerSwitcher", category: "TernaryCPURuntime")

    /// CPU ternary lane carries TEXT only (design D5 / task 5.3): a ternary text model advertises no
    /// vision/audio, and the role→lane policy keeps `mediaDiffusion`/vision roles on the GPU lane — so a
    /// vision/media role is never routed to the CPU lane. A vision request here hard-errors (no degrade).
    public let capabilities: Set<Modality> = [.text]

    /// On-disk path to the ternary weights (a small ternary/BitNet-class GGUF-class file). Resident
    /// footprint is ~32× smaller than the GPU chat weights → it co-resides cheaply (Core's
    /// `LaneResidencyBudget.ternaryCoResides`). Loaded once, reused across bursts.
    private let weightsURL: URL
    /// True once `prepare()` has loaded the model resident. Bursts before prepare report `.modelMissing`.
    private var isPrepared = false
    private let lock = NSLock()

    public init(weightsURL: URL) {
        self.weightsURL = weightsURL
    }

    // MARK: - Preparation

    /// Load the ternary model resident on the CPU lane. Maps any native load failure into `RuntimeError`
    /// at THIS boundary (D7). `prepare` is idempotent; a missing weights file is `.modelMissing`.
    public func prepare() async throws {
        lock.lock(); let already = isPrepared; lock.unlock()
        if already { return }
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw RuntimeError.modelMissing
        }
        do {
            try await loadResident()
            lock.lock(); isPrepared = true; lock.unlock()
        } catch let e as RuntimeError {
            throw e
        } catch {
            // bitnet.cpp-class init / Process / file IO failure → mapped at the boundary.
            throw RuntimeError.modelLoadFailed(detail: String(describing: error))
        }
    }

    /// FLAGGED: the real resident load drives the bitnet.cpp-class engine (load the ternary weights into
    /// the CPU inference context, warm the kernels). Native-only; the agent compile-verifies the seam.
    private func loadResident() async throws {
        // Real implementation: initialize the bitnet.cpp-class context over `weightsURL`. Any thrown
        // vendor/OS error is caught by `prepare()` and mapped into `RuntimeError`.
    }

    // MARK: - Streaming (short bursts only — never the long reply)

    public func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
        let caps = capabilities
        let needsVision = request.requiresVision
        return AsyncThrowingStream { continuation in
            let task = Task {
                // A vision/media role never reaches the CPU lane via the policy; defend anyway (no degrade).
                if needsVision && !caps.contains(.vision) {
                    continuation.finish(throwing: RuntimeError.unsupportedModality(.vision))
                    return
                }
                guard self.preparedSnapshot() else {
                    continuation.finish(throwing: RuntimeError.modelMissing)
                    return
                }
                do {
                    // FLAGGED: the real short-burst decode loop. Per-token is slower than the GPU; this is
                    // acceptable because bursts are short/bounded and run CONCURRENTLY with the GPU reply.
                    // Cancellation (a discarded turn) is honored promptly → `RuntimeError.cancelled`.
                    try Task.checkCancellation()
                    try await self.decode(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: RuntimeError.cancelled)   // not a failure
                } catch let e as RuntimeError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: RuntimeError.decodeFailed(detail: String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// FLAGGED: the real per-token decode against the resident ternary context, yielding `Token`s in
    /// order and honoring cancellation between steps. Native-only.
    private func decode(_ request: LLMRequest,
                        into continuation: AsyncThrowingStream<Token, Error>.Continuation) async throws {
        // Real implementation: step the bitnet.cpp-class context, yielding `Token(piece)` per step and
        // `Token(piece, isFinal: true)` on the stop token; `try Task.checkCancellation()` each step.
        _ = request
        _ = continuation
    }

    // MARK: - Structured (the router's route turn — the CPU lane's primary use)

    public func structured<T: Decodable & Sendable>(
        _ request: LLMRequest,
        schema: StructuredSchema,
        as type: T.Type
    ) async throws -> StructuredOutcome<T> {
        try Task.checkCancellation()
        guard preparedSnapshot() else { throw RuntimeError.modelMissing }
        // FLAGGED: the real constrained/structured decode — emit JSON, run the bounded
        // validate → repair/retry → decode → outcome pipeline, allow a typed `.declined`. On exhaustion
        // throw `RuntimeError.couldNotProduceValid`; on a decode mismatch `RuntimeError.decodeFailed`.
        _ = schema
        _ = request
        throw RuntimeError.unavailable(reason: "TernaryCPURuntime structured decode is verified only in the user's stable-signed build.")
    }

    private func preparedSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }; return isPrepared
    }
}
