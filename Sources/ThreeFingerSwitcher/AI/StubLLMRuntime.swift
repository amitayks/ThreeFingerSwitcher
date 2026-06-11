import Foundation

/// A deterministic, scriptable `LLMRuntime` for tests and `swift build`/`swift test` (the real
/// Gemma-4-via-MLX conformer is deferred to an `xcodebuild`-only target — see design D7).
///
/// It exercises every contract path without a model:
/// - scripted text responses, streamed token-by-token with an artificial inter-token delay,
/// - prompt Task cancellation honored (stops emitting on cancel),
/// - scriptable `structured(...)` outcomes: a valid value, a "non-conforming first, then repaired"
///   sequence (so the bounded repair/retry loop is observable), or an explicit decline.
///
/// `Sendable` via `@unchecked`: the mutable scripting state is intended to be configured before use
/// in a single-threaded test and is not mutated concurrently. A lock guards the per-call counter so
/// the repair-path test is robust even under concurrency.
public final class StubLLMRuntime: LLMRuntime, @unchecked Sendable {

    // MARK: Structured scripting

    /// How `structured(...)` should behave for the next call(s). The stub interprets these as raw
    /// JSON payloads it would "emit" and then runs the real validate → repair/retry → decode → outcome
    /// pipeline over them, so the production code path (not a shortcut) is what tests cover.
    public enum StructuredScript: Sendable {
        /// Emit this exact JSON on the first attempt; it should validate + decode cleanly.
        case valid(json: String)
        /// Emit `bad` JSON first (fails validation), then `good` on the repair attempt. Proves the
        /// bounded repair/retry loop converges.
        case invalidThenRepaired(bad: String, good: String)
        /// Emit a decline marker so the pipeline returns `.declined(reason:)` instead of a value.
        case decline(reason: String)
        /// Always emit non-conforming JSON; the bounded loop should exhaust and throw
        /// `couldNotProduceValid`.
        case alwaysInvalid(json: String)
    }

    // MARK: Configuration

    /// Modalities this stub reports. Default = text + vision (mirrors the v1 flagship); a test can
    /// construct a text-only stub to exercise the unsupported-modality path.
    public let capabilities: Set<Modality>

    /// Scripted streaming chunks emitted, in order, for every `generate(_:)` call. If empty, the stub
    /// echoes the request prompt as a single token. These are RESPONSE-channel chunks (the final answer).
    var scriptedTokens: [String]

    /// Scripted REASONING chunks, emitted as `.thinking`-channel tokens BEFORE the response tokens (so a
    /// test can drive the canvas's "show the model's thinking" channel split). Default empty = today's
    /// behavior: a pure `.response` stream, byte-identical to before.
    var scriptedThinking: [String]

    /// Artificial delay between emitted tokens, in nanoseconds. Lets a test observe streaming order
    /// and cancel mid-stream. Default is a tiny delay so tests stay fast.
    var interTokenDelayNanos: UInt64

    /// Scripted behavior for the next `structured(...)` call. nil → a generic empty-object attempt.
    var structuredScript: StructuredScript?

    /// Bounded repair/retry budget for `structured(...)` (total attempts including the first).
    var maxRepairAttempts: Int

    /// Records how many attempts the last `structured(...)` call consumed (for assertions).
    private(set) var lastAttemptCount: Int = 0

    /// True once a `generate(_:)` stream detected cancellation and stopped emitting. Deterministic
    /// observation point for "cancellation stops generation" — independent of the consumer-side race
    /// where a self-cancelled `AsyncThrowingStream` iterator terminates before the thrown terminal
    /// error is observed.
    private var didObserveCancellation = false
    var observedCancellation: Bool {
        lock.lock(); defer { lock.unlock() }; return didObserveCancellation
    }

    private let lock = NSLock()

    public init(capabilities: Set<Modality> = [.text, .vision],
                scriptedTokens: [String] = [],
                scriptedThinking: [String] = [],
                interTokenDelayNanos: UInt64 = 1_000_000, // 1 ms
                structuredScript: StructuredScript? = nil,
                maxRepairAttempts: Int = 3) {
        self.capabilities = capabilities
        self.scriptedTokens = scriptedTokens
        self.scriptedThinking = scriptedThinking
        self.interTokenDelayNanos = interTokenDelayNanos
        self.structuredScript = structuredScript
        self.maxRepairAttempts = maxRepairAttempts
    }

    // MARK: Streaming

    public func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
        // Capture the script up-front so the closure doesn't race on `self` mutation mid-stream.
        let chunks = scriptedTokens.isEmpty ? [request.prompt] : scriptedTokens
        let thinkingChunks = scriptedThinking
        let delay = interTokenDelayNanos
        let needsVision = request.requiresVision
        let caps = capabilities

        return AsyncThrowingStream { continuation in
            let task = Task {
                // A vision request against a text-only stub is a hard error, never a silent degrade.
                if needsVision && !caps.contains(.vision) {
                    continuation.finish(throwing: RuntimeError.unsupportedModality(.vision))
                    return
                }
                do {
                    // Reasoning first: `.thinking`-channel chunks stream BEFORE the response (so a
                    // consumer can split the model's thinking from its answer). isFinal stays false —
                    // only the last RESPONSE token is final. Empty by default (a pure response stream).
                    for chunk in thinkingChunks {
                        try Task.checkCancellation()
                        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                        try Task.checkCancellation()
                        continuation.yield(Token(chunk, isFinal: false, channel: .thinking))
                    }
                    for (i, chunk) in chunks.enumerated() {
                        // Honor cancellation BEFORE emitting so a discard stops work promptly.
                        try Task.checkCancellation()
                        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                        try Task.checkCancellation()
                        continuation.yield(Token(chunk, isFinal: i == chunks.count - 1))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    self.markCancelled()
                    continuation.finish(throwing: RuntimeError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Structured

    /// A decline marker the stub recognizes in "model output". The validate/repair pipeline treats a
    /// payload carrying this as a first-class `.declined` rather than a decode failure.
    static let declineMarkerKey = "__declined__"

    public func structured<T: Decodable & Sendable>(
        _ request: LLMRequest,
        schema: StructuredSchema,
        as type: T.Type
    ) async throws -> StructuredOutcome<T> {
        try Task.checkCancellation()

        let script = structuredScript ?? .valid(json: "{}")
        let budget = max(1, maxRepairAttempts)

        // The bounded validate → repair/retry loop, run over the scripted "model emissions".
        var attempts = 0
        var lastDecodeDetail = ""

        while attempts < budget {
            try Task.checkCancellation()
            attempts += 1
            let raw = Self.emission(for: script, attempt: attempts)

            // 1) Decline detection: a declined emission short-circuits to a typed decline.
            if let reason = Self.declineReason(in: raw) {
                setLastAttemptCount(attempts)
                return .declined(reason: reason)
            }

            // 2) Validate against the schema (structural validation; see `validate`).
            guard let data = raw.data(using: .utf8),
                  Self.validate(jsonData: data, against: schema) else {
                lastDecodeDetail = "schema validation failed on attempt \(attempts)"
                continue // repair/retry
            }

            // 3) Decode into the target Swift type.
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                setLastAttemptCount(attempts)
                return .value(decoded)
            } catch {
                lastDecodeDetail = "decode failed: \(error)"
                continue // a structurally-valid-but-undecodable payload is also repairable
            }
        }

        setLastAttemptCount(attempts)
        _ = lastDecodeDetail
        throw RuntimeError.couldNotProduceValid(attempts: attempts)
    }

    // MARK: - Scripting helpers

    /// What the stub "emits" on a given attempt for a script.
    private static func emission(for script: StructuredScript, attempt: Int) -> String {
        switch script {
        case let .valid(json):
            return json
        case let .invalidThenRepaired(bad, good):
            return attempt == 1 ? bad : good
        case let .decline(reason):
            return "{\"\(declineMarkerKey)\": \"\(reason)\"}"
        case let .alwaysInvalid(json):
            return json
        }
    }

    /// If the raw emission is a decline marker, return its reason.
    private static func declineReason(in raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = obj[declineMarkerKey] as? String else { return nil }
        return reason
    }

    /// Structural schema validation: parse the JSON and check it carries every property named in the
    /// schema's top-level `required` array (a pragmatic subset of JSON Schema sufficient to drive the
    /// validate/repair/decode pipeline deterministically in tests). Non-object JSON or malformed input
    /// fails validation, which the loop then repairs.
    static func validate(jsonData: Data, against schema: StructuredSchema) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return false
        }
        let required = requiredKeys(fromSchemaJSON: schema.json)
        for key in required where value[key] == nil {
            return false
        }
        return true
    }

    /// Extract the `required: [...]` string array from a JSON-Schema document string. Returns an empty
    /// set if absent (a schema with no required keys accepts any object).
    private static func requiredKeys(fromSchemaJSON json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let required = obj["required"] as? [String] else { return [] }
        return Set(required)
    }

    private func setLastAttemptCount(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        lastAttemptCount = n
    }

    private func markCancelled() {
        lock.lock(); defer { lock.unlock() }
        didObserveCancellation = true
    }
}
