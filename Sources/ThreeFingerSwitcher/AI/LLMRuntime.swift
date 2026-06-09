import Foundation

/// The on-device model layer's single seam. Feature code (the band, the executor, the tasks)
/// depends ONLY on this file — never on a concrete model or framework — so that an additional
/// model (another Gemma 4 size, a future Gemma, Apple Foundation Models, or a cloud model) can be
/// added later as one new conformer without touching feature code (see design D1).
///
/// The real Gemma-4-via-MLX conformer is DEFERRED to a separate `xcodebuild`-only target; this
/// slice ships only `StubLLMRuntime`, which exercises every path below deterministically.

// MARK: - Modality

/// What kinds of input a runtime (or a model descriptor) can handle. A vision command requires a
/// `.vision`-capable runtime; `.audio` is reserved for a future audio-capable Gemma 4 so an audio
/// command can be routed without changing feature code.
public enum Modality: String, Codable, Sendable, CaseIterable {
    case text
    case vision
    case audio
}

// MARK: - Request

/// Generation tuning knobs. Pragmatic defaults; the executor overrides per command.
public struct GenerationParameters: Equatable, Sendable {
    /// Hard cap on emitted tokens (a safety bound on runaway generation).
    public var maxTokens: Int
    /// Sampling temperature. 0 ≈ greedy/deterministic; higher = more varied.
    public var temperature: Double

    public static let `default` = GenerationParameters(maxTokens: 1024, temperature: 0.7)

    public init(maxTokens: Int = 1024, temperature: Double = 0.7) {
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// One unit of model work: a text prompt, optional image bytes for vision, and tuning.
/// `image` carries encoded image data (e.g. PNG of a captured screen region); a `.text`-only
/// runtime ignores it. Kept a value type so requests are cheap to build and pass around.
public struct LLMRequest: Sendable {
    /// The fully-resolved prompt text (templating happens upstream in the executor).
    public var prompt: String
    /// Optional encoded image for `.vision` requests (nil for text-only).
    public var image: Data?
    public var parameters: GenerationParameters

    public init(prompt: String, image: Data? = nil, parameters: GenerationParameters = .default) {
        self.prompt = prompt
        self.image = image
        self.parameters = parameters
    }

    /// Whether this request needs a `.vision`-capable runtime.
    public var requiresVision: Bool { image != nil }
}

// MARK: - Streaming token

/// One incremental chunk of streamed output. A runtime emits these in order as the model produces
/// them; the preview canvas concatenates `text` to render generation live (design D4).
public struct Token: Equatable, Sendable {
    /// The piece of text produced for this step (a sub-word, word, or fragment).
    public var text: String
    /// True for the final token of a stream (lets a consumer finalize without waiting on stream end).
    public var isFinal: Bool

    public init(_ text: String, isFinal: Bool = false) {
        self.text = text
        self.isFinal = isFinal
    }
}

// MARK: - Structured output

/// A JSON-Schema wrapper handed to `structured(...)`. We carry the schema as a string (its JSON
/// representation) rather than a parsed tree so it can be embedded in prompts, logged, and validated
/// uniformly across conformers. `name` labels the target shape for the model's benefit.
public struct StructuredSchema: Equatable, Sendable {
    /// A short identifier for the target shape (e.g. "calendar_event").
    public var name: String
    /// The JSON Schema document, as a JSON string.
    public var json: String

    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}

/// The result of a `structured(...)` call: EITHER a validated, decoded value, OR an explicit
/// decline. The decline path is first-class on purpose (design D2): the model is allowed to refuse
/// — "this isn't a meeting" — instead of being forced to fabricate a well-formed-but-false value.
public enum StructuredOutcome<Value>: Sendable where Value: Sendable {
    /// The model produced output that validated against the schema and decoded into `Value`.
    case value(Value)
    /// The model declined the task as not applicable; carries a human-readable reason.
    case declined(reason: String)

    /// The decoded value if produced, else nil (decline).
    public var value: Value? {
        if case let .value(v) = self { return v }
        return nil
    }

    /// The decline reason if declined, else nil.
    public var declineReason: String? {
        if case let .declined(reason) = self { return reason }
        return nil
    }

    public var isDeclined: Bool {
        if case .declined = self { return true }
        return false
    }
}

// MARK: - Errors

/// Failures the runtime layer can report. Distinct cases so the UI can message precisely (a missing
/// model asks for a download; an integrity failure asks for a re-download; `unavailable` is the
/// "this machine/config can't serve the feature" terminal state — never a silent degrade).
public enum RuntimeError: Error, Equatable {
    /// The feature can't be served on this machine/configuration (no silent fallback).
    case unavailable(reason: String)
    /// Weights are not present (not yet downloaded).
    case modelMissing
    /// A downloaded model failed its integrity (SHA) check; it must not be loaded.
    case integrityFailed
    /// The work was cancelled mid-flight (Task cancellation / discard).
    case cancelled
    /// `structured(...)` exhausted its bounded repair/retry loop without a conforming value.
    case couldNotProduceValid(attempts: Int)
    /// Output could not be decoded into the requested `Decodable` type.
    case decodeFailed(detail: String)
    /// The runtime lacks a capability the request needs (e.g. vision asked of a text-only model).
    case unsupportedModality(Modality)
}

// MARK: - The protocol

/// The swappable model runtime. All language-model functionality is reached through this.
///
/// Conformers must:
/// - declare their `capabilities` so capability-based selection can route correctly,
/// - stream text via `generate(_:)`, honoring Task cancellation promptly (discard stops work),
/// - and serve `structured(_:schema:as:)` by validating against the schema, repairing/retrying
///   within a bounded loop on mismatch, and allowing a typed `.declined` outcome rather than
///   fabricating a value.
public protocol LLMRuntime: Sendable {
    /// The modalities this runtime can serve.
    var capabilities: Set<Modality> { get }

    /// Stream generated text token-by-token. Cancelling the consuming Task SHALL stop generation
    /// promptly (the stream finishes; no further tokens are emitted).
    func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error>

    /// Produce a schema-targeted, validated, decoded structured value — or a typed decline.
    ///
    /// The contract (design D2): request output matching `schema`, VALIDATE it, REPAIR/RETRY within a
    /// bounded loop on mismatch, decode into `T`, and allow a `.declined` outcome when the input does
    /// not fit the task. Throws `RuntimeError.couldNotProduceValid` only when the bounded loop is
    /// exhausted without a conforming value (and the model did not decline).
    func structured<T: Decodable & Sendable>(
        _ request: LLMRequest,
        schema: StructuredSchema,
        as type: T.Type
    ) async throws -> StructuredOutcome<T>
}

extension LLMRuntime {
    /// Convenience: collect a full generation into a single string (used by tests and non-streaming
    /// callers). Propagates cancellation and errors from the underlying stream.
    public func generateText(_ request: LLMRequest) async throws -> String {
        var out = ""
        for try await token in generate(request) {
            out += token.text
        }
        return out
    }
}
