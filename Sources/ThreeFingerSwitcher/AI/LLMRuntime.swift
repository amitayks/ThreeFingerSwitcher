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

/// One unit of model work: a text prompt, encoded image bytes for vision (a turn may carry MULTIPLE —
/// design D2), and tuning. `images` carries encoded image data (e.g. PNGs of captured regions); a
/// `.text`-only runtime ignores them. Kept a value type so requests are cheap to build and pass around.
public struct LLMRequest: Sendable {
    /// The fully-resolved prompt text (templating happens upstream in the executor).
    public var prompt: String
    /// Encoded images for a `.vision` request (empty for text-only). A SINGLE turn may carry MULTIPLE
    /// images (design D2); the runtime feeds each to the model input.
    public var images: [Data]
    public var parameters: GenerationParameters
    /// When true, the runtime should let the model think (reasoning) but stream/return only the final
    /// response — never the thinking.
    public var reasoning: Bool

    /// The FIRST image, or nil — the single-image convenience (design D2: `images` is the source of truth).
    public var image: Data? { images.first }

    /// Designated init (multi-image). `images` defaults to `[]`.
    public init(prompt: String, images: [Data] = [], parameters: GenerationParameters = .default,
                reasoning: Bool = false) {
        self.prompt = prompt
        self.images = images
        self.parameters = parameters
        self.reasoning = reasoning
    }

    /// Single-image convenience (design D2): folds one optional image into `images` so existing callers
    /// (`LLMRequest(prompt:image:)`) keep compiling unchanged. A nil image yields `[]`.
    public init(prompt: String, image: Data?, parameters: GenerationParameters = .default,
                reasoning: Bool = false) {
        self.init(prompt: prompt, images: image.map { [$0] } ?? [],
                  parameters: parameters, reasoning: reasoning)
    }

    /// Whether this request needs a `.vision`-capable runtime (it carries at least one image).
    public var requiresVision: Bool { !images.isEmpty }
}

/// A multi-turn conversation request: a role-tagged message list (already compacted upstream by the
/// executor) plus the same tuning the single-prompt `LLMRequest` carries. Additive over `LLMRequest`
/// (design D2 / blueprint §3.2) — served by `LLMRuntime.chat(_:)`, which is default-implemented in terms
/// of `generate(_:)` so existing conformers work unchanged. `tools` is declared in its final shape for
/// route-mode (owned by `ai-tool-routing`); this slice leaves it nil and ignores it.
public struct LLMChatRequest: Sendable {
    /// The role-tagged multi-turn context. The conversation's reasoning is NOT re-fed: the assembler
    /// (`ChatTemplate.flatten`, or a conformer's chat template) reads each message's committed `text` only.
    public var messages: [AgentMessage]
    /// The turn's images (design D2 — ALL of the latest turn's images, not just one); a `.vision`-capable
    /// runtime is required when non-empty. Empty = a text turn.
    public var images: [Data]
    public var parameters: GenerationParameters
    /// When true, the runtime lets the model think but streams/returns only the final response.
    public var reasoning: Bool
    /// Advertised tools for route-mode (owned by `ai-tool-routing`); nil = plain chat (this slice).
    public var tools: [ToolDescriptor]?

    /// The FIRST request-level image, or nil — the single-image convenience (design D2).
    public var image: Data? { images.first }

    /// Designated init (multi-image). `images` defaults to `[]`.
    public init(messages: [AgentMessage],
                images: [Data] = [],
                parameters: GenerationParameters = .default,
                reasoning: Bool = false,
                tools: [ToolDescriptor]? = nil) {
        self.messages = messages
        self.images = images
        self.parameters = parameters
        self.reasoning = reasoning
        self.tools = tools
    }

    /// Single-image convenience (design D2): folds one optional image into `images` so existing callers
    /// (`LLMChatRequest(messages:image:)`) keep compiling unchanged. A nil image yields `[]`.
    public init(messages: [AgentMessage],
                image: Data?,
                parameters: GenerationParameters = .default,
                reasoning: Bool = false,
                tools: [ToolDescriptor]? = nil) {
        self.init(messages: messages, images: image.map { [$0] } ?? [],
                  parameters: parameters, reasoning: reasoning, tools: tools)
    }

    /// ALL of the effective turn's images (design D2): the request-level `images` if set, else the latest
    /// message that carries images. Forwarded in full to the runtime so a multi-image turn reaches the model.
    public var effectiveImages: [Data] {
        if !images.isEmpty { return images }
        return messages.last(where: { !$0.images.isEmpty })?.images ?? []
    }

    /// The latest effective image (first of `effectiveImages`), for single-image consumers/tests.
    public var effectiveImage: Data? { effectiveImages.first }
}

// MARK: - Streaming token

/// Which channel a streamed token belongs to (design: "show the model's thinking"). The runtime
/// classifies each chunk as either the model's reasoning (`.thinking`) or the final answer
/// (`.response`); the preview canvas streams `.thinking` into a collapsible section and commits ONLY
/// `.response`. Legacy emitters that don't classify default to `.response`, so today's behavior — a
/// single response stream — is byte-identical until a runtime opts into emitting `.thinking`.
public enum TokenChannel: Equatable, Sendable {
    /// The final answer — accumulated, streamed into `state`, and committed.
    case response
    /// The model's reasoning — streamed into the canvas's collapsible Thinking section, NEVER committed.
    case thinking
}

/// One incremental chunk of streamed output. A runtime emits these in order as the model produces
/// them; the preview canvas concatenates `text` to render generation live (design D4). `channel`
/// classifies the chunk as the model's reasoning (`.thinking`) or its final answer (`.response`) so
/// the canvas can split the two — thinking is shown but never committed.
public struct Token: Equatable, Sendable {
    /// The piece of text produced for this step (a sub-word, word, or fragment).
    public var text: String
    /// True for the final token of a stream (lets a consumer finalize without waiting on stream end).
    public var isFinal: Bool
    /// Which channel this chunk belongs to. Defaults to `.response` so existing emitters/tests that
    /// build `Token(text)` keep compiling and mean "final answer".
    public var channel: TokenChannel

    public init(_ text: String, isFinal: Bool = false, channel: TokenChannel = .response) {
        self.text = text
        self.isFinal = isFinal
        self.channel = channel
    }
}

// MARK: - Structured output

/// A JSON-Schema wrapper handed to `structured(...)`. We carry the schema as a string (its JSON
/// representation) rather than a parsed tree so it can be embedded in prompts, logged, and validated
/// uniformly across conformers. `name` labels the target shape for the model's benefit.
public struct StructuredSchema: Codable, Equatable, Sendable {
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
///
/// This is the SHARED error taxonomy for the AI feature (design D1/D6): each runtime backend maps its
/// own native errors (e.g. a vendor download-library error, an `NSURLError`) into these cases at its
/// boundary, so feature/UI code only ever sees this type — never a raw vendor/OS error. The taxonomy
/// is `LocalizedError` so every case is self-describing with a clean, user-facing string; the central
/// `AIError.message(for:)` translator routes through that `errorDescription` (never a reflected enum
/// dump). Associated values stay `Equatable` (and carry no non-`Equatable` `Error`) so the enum is
/// `Equatable` — copyable raw detail rides on `AIPresentedError.details`, derived at translation time.
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
    /// No internet connection reached the model service (e.g. provision/download with wifi off).
    case offline
    /// The model service was reachable but could not serve the request (5xx, transient outage).
    case serverUnavailable
    /// Access to the model was refused (auth/forbidden/not-found at the download endpoint).
    case authOrAccessDenied
    /// The weights downloaded but could not be loaded into the runtime. `detail` is opt-in copyable
    /// diagnostic text (kept off the user-facing headline; surfaced only as `AIPresentedError.details`).
    case modelLoadFailed(detail: String?)
}

/// Self-describing, user-facing messages for every case (so the "clean path" — reading
/// `errorDescription` — never falls back to a reflected enum dump). These are the canonical strings
/// the central `AIError.message(for:)` translator returns as the headline; raw error text never
/// appears here, only in opt-in `details`/logs (spec: "No raw error text in user-facing strings").
extension RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return reason
        case .modelMissing: return "The model is not downloaded yet."
        case .integrityFailed: return "The model failed its integrity check; re-download required."
        case .cancelled: return "Cancelled."
        case let .couldNotProduceValid(attempts): return "Could not produce a valid result (\(attempts) attempts)."
        case .decodeFailed: return "Could not read the model's result."
        case let .unsupportedModality(modality): return "The model can't handle \(modality.rawValue) input."
        case .offline: return "No internet connection. Connect to the internet and try again."
        case .serverUnavailable: return "The model service is temporarily unavailable. Please try again shortly."
        case .authOrAccessDenied: return "Access to the model was denied. It may require sign-in or has moved."
        case .modelLoadFailed: return "The model could not be loaded."
        }
    }
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

    /// Stream a multi-turn conversation token-by-token. ADDITIVE (design D2): declared as a requirement
    /// WITH a default implementation in the extension below, so (a) existing conformers
    /// (`StubLLMRuntime`, `DevAIRuntime`, the Gemma conformer) keep compiling UNCHANGED — they inherit
    /// the default — while (b) a conformer that overrides it (the batched MLX runtime, for true KV-reuse)
    /// is dispatched correctly when called through the `LLMRuntime` existential. Declaring it only in the
    /// extension would static-dispatch to the default and silently ignore the override.
    func chat(_ request: LLMChatRequest) -> AsyncThrowingStream<Token, Error>
}

extension LLMRuntime {
    /// DEFAULT multi-turn implementation (design D2 / blueprint §3.2): flatten the message list into one
    /// prompt via the model-agnostic `ChatTemplate`, then serve it through `generate(_:)` — passing
    /// `image`/`reasoning`/`parameters` straight through so the `.thinking`/`.response` channel split and
    /// the vision path are inherited for free. Existing conformers get multi-turn with no change; the
    /// batched MLX conformer OVERRIDES this for true key/value-cache reuse across turns.
    public func chat(_ request: LLMChatRequest) -> AsyncThrowingStream<Token, Error> {
        let prompt = ChatTemplate.flatten(request.messages)
        return generate(LLMRequest(prompt: prompt,
                                   images: request.effectiveImages,   // ALL of the turn's images (design D2)
                                   parameters: request.parameters,
                                   reasoning: request.reasoning))
    }

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

// MARK: - Batched (continuous-batching) runtime

/// A runtime that multiplexes K conversation streams over ONE weight read per decode step (blueprint
/// §3.6, `ai-batched-runtime-and-context`). Decode is memory-bandwidth-bound — K independent
/// `generate()` calls would re-read the ~17 GB weights K times (K× bandwidth, no win); continuous
/// batching reads the weights once and advances K streams together. `maxConcurrentStreams` is RAM-derived
/// (see `ConcurrencyBudget`), not a constant, because the per-stream KV cache grows with context.
///
/// MLX-free Core declares the seam; the real conformer (`BatchedGemmaMLXRuntime`) lives in GemmaRuntime
/// and is `xcodebuild` compile-verified only. It refines `LLMRuntime`, so the foreground `chat()` path is
/// unchanged (a single-session `chat` is just a K=1 batch).
public protocol BatchedLLMRuntime: LLMRuntime {
    /// Advance K streams one batched step at a time, de-multiplexing each emitted token back to its
    /// session. New requests may join mid-flight (continuous, not static, batching); a finished stream
    /// frees its slot for the next runnable session with the weights still resident.
    func batchStep(_ requests: [AgentSessionID: LLMChatRequest])
        -> AsyncThrowingStream<(AgentSessionID, Token), Error>

    /// K — how many streams fit RIGHT NOW, derived from free RAM at the current context length and
    /// KV-quant bits (recomputed when the context setting changes or memory pressure is reported).
    var maxConcurrentStreams: Int { get }
}
