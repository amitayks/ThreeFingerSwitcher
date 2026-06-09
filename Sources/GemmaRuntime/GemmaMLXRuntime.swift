// GemmaMLXRuntime — the real, in-process Gemma 4 conformer of Core's `LLMRuntime` seam.
//
// It wraps a `Gemma4Pipeline` (from the `Gemma4Swift` package → mlx-swift) and bridges it to the
// Core protocol that all feature code depends on. This file links MLX (Metal shaders), so it lives
// in the isolated `GemmaRuntime` target and is only ever built via `xcodebuild` — Core and the test
// target never see it (design D1/D7).

import Foundation
import os
import ThreeFingerSwitcherCore
import Gemma4Swift

/// In-process Gemma 4 (MLX) implementation of `LLMRuntime`.
///
/// VISION IS DEFERRED in v1: `Gemma4Pipeline.chatStream(...)` is text-only (a `String` prompt → token
/// strings; no image-bearing streaming entry point), so this runtime advertises `[.text]` only and
/// `generate` REFUSES an image-bearing request with `RuntimeError.unsupportedModality(.vision)` rather
/// than silently degrading it to a text-only answer (design: "never a silent degrade" — the executor
/// surfaces this as "The model can't handle vision input."). Note the model itself is vision-capable
/// and a registry descriptor may advertise `.vision`; it is THIS runtime impl that doesn't yet
/// implement it. Widening to vision is a future extension (an image-aware pipeline call + `.vision`).
///
/// CANCELLATION: discarding the consumer stops token DELIVERY and surfaces `.cancelled` promptly, but
/// it does NOT tear down the underlying MLX generation — the vendored `Gemma4Pipeline.chatStream`
/// wrapper task doesn't forward stream termination, so GPU work runs on to `maxTokens` in the
/// background. (A future fix would drive the `ChatSession` stream directly, which cancels properly.)
///
/// `@unchecked Sendable`: the wrapped `@MainActor`-isolated pipeline is only ever touched on the main
/// actor (every hop into it is `@MainActor`); the reference itself is immutable after init.
public final class GemmaMLXRuntime: LLMRuntime, @unchecked Sendable {

    /// The MLX-backed pipeline. `@MainActor` per `Gemma4Pipeline`'s own isolation.
    private let pipeline: Gemma4Pipeline

    /// v1: text-only (see the type doc — `chatStream` is text-only). Vision is a deferred extension.
    public let capabilities: Set<Modality> = [.text]

    /// Breadcrumbs to the unified log so a hard SIGKILL (hang→force-quit, OOM, Metal abort) that leaves
    /// NO `.ips` crash report is still diagnosable: `log show --predicate 'subsystem=="ThreeFingerSwitcher"'`
    /// reveals exactly which phase (download / load / generate) the process died in.
    static let log = Logger(subsystem: "ThreeFingerSwitcher", category: "GemmaMLXRuntime")

    /// Create a runtime over a fresh pipeline. Use `prepare(...)` to download/load weights.
    /// `@MainActor` so it can construct the `@MainActor`-isolated `Gemma4Pipeline`.
    @MainActor
    public convenience init() {
        self.init(pipeline: Gemma4Pipeline())
    }

    /// Wrap an existing pipeline (it may already be loaded). Use `prepare(...)` to load weights.
    @MainActor
    public init(pipeline: Gemma4Pipeline) {
        self.pipeline = pipeline
    }

    // MARK: - Preparation (download + load)

    /// Download (if needed) and load `model` into the pipeline, reporting a 0…1 fraction.
    ///
    /// Download is delegated to `GemmaResumableDownloader`, which streams each weight/config file to a
    /// `{dest}.part` on disk and resumes via HTTP `Range` after a network drop — so a flaky-wifi failure
    /// mid-shard keeps its partial bytes and the next attempt picks up where it left off (the vendored
    /// downloader had NO byte resume and failed permanently on `NSURLErrorDomain -1005`). It writes into
    /// the exact cache layout `Gemma4ModelCache` reads, so once it returns we load with
    /// `downloadIfNeeded: false`. `progress` is the downloader's 0…1 byte fraction. Called from
    /// `GemmaRuntime.makeModelManager`'s provisioner.
    @MainActor
    public func prepare(
        model: Gemma4Pipeline.Model,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if Task.isCancelled { throw RuntimeError.cancelled }
        Self.log.notice("prepare: begin \(model.rawValue, privacy: .public)")
        do {
            // Cache dir = `<caches>/models/{org}/{model}` — exactly what `Gemma4ModelCache` reads (it
            // exposes `modelsDirectory` publicly, so build the path off that instead of duplicating it).
            var modelDir = Gemma4ModelCache.modelsDirectory
            for part in model.rawValue.split(separator: "/") {
                modelDir = modelDir.appendingPathComponent(String(part))
            }

            // Byte-resumable download (the downloader owns its own retry/backoff per file).
            try await GemmaResumableDownloader.ensureModel(model, into: modelDir, progress: progress)

            // The cache is now complete on disk, so load straight from it (no further download).
            // Load the TEXT-ONLY graph (multimodal: false) — vision/audio towers would only waste
            // memory + load time on the ~17 GB model for this text-only runtime.
            Self.log.notice("prepare: download complete → loading weights into MLX (this is the heavy step)…")
            try await pipeline.load(model, multimodal: false, downloadIfNeeded: false)
            Self.log.notice("prepare: model loaded and ready ✓")
        } catch is CancellationError {
            Self.log.notice("prepare: cancelled")
            throw RuntimeError.cancelled
        } catch let runtime as RuntimeError {
            // Already in the shared taxonomy (e.g. an inner `.cancelled`) — log + rethrow unchanged.
            Self.log.error("prepare: FAILED: \(String(describing: runtime), privacy: .public)")
            throw runtime
        } catch let download as Gemma4DownloadError {
            // Map the vendored download-library error into the shared taxonomy HERE, at the boundary
            // (design D6) — stop re-throwing it raw. The diagnostic log line is KEEP-as-is.
            Self.log.error("prepare: FAILED: \(String(describing: download), privacy: .public)")
            throw Self.runtimeError(for: download)
        } catch {
            // Any other failure is a model-load failure; carry the raw text as OPT-IN detail only
            // (never the user-facing headline). The diagnostic log line is KEEP-as-is.
            Self.log.error("prepare: FAILED: \(String(describing: error), privacy: .public)")
            throw RuntimeError.modelLoadFailed(detail: String(describing: error))
        }
    }

    /// Map the vendored `Gemma4DownloadError` into Core's shared `RuntimeError` taxonomy. Reference the
    /// vendored type by its PUBLIC shape only — never edit it (it lives in `.build/checkouts`). For a
    /// `.networkError`, inspect the wrapped `NSError` code to split a genuine offline state from a
    /// transient server failure; HTTP statuses reuse `AIError`'s shared classifier so the boundary and
    /// the translator never disagree.
    static func runtimeError(for error: Gemma4DownloadError) -> RuntimeError {
        switch error {
        case let .networkError(_, underlying):
            switch (underlying as NSError).code {
            case NSURLErrorNotConnectedToInternet,   // -1009
                 NSURLErrorNetworkConnectionLost,     // -1005
                 NSURLErrorCannotConnectToHost,       // -1004
                 NSURLErrorCannotFindHost,            // -1003
                 NSURLErrorDNSLookupFailed,           // -1006
                 NSURLErrorTimedOut,                  // -1001
                 NSURLErrorDataNotAllowed,            // -1020
                 NSURLErrorInternationalRoamingOff:   // -1018
                return .offline
            default:
                return .serverUnavailable
            }
        case let .httpError(_, code):
            return AIError.runtimeError(forHTTPStatus: code) ?? .serverUnavailable
        case .apiFailed, .parseError, .noFilesFound:
            return .serverUnavailable
        case .cancelled:
            return .cancelled
        }
    }

    // MARK: - Streaming text generation

    public func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
        let prompt = request.prompt
        let temperature = Float(request.parameters.temperature)
        let maxTokens = request.parameters.maxTokens
        let needsVision = request.requiresVision
        let pipeline = self.pipeline

        return AsyncThrowingStream { continuation in
            // Honest refusal (NOT a silent degrade): this runtime is text-only in v1, so a request
            // carrying image bytes is rejected — the executor maps `.unsupportedModality` to a clear
            // "The model can't handle vision input." message rather than answering about nothing.
            if needsVision {
                continuation.finish(throwing: RuntimeError.unsupportedModality(.vision))
                return
            }
            let task = Task { @MainActor in
                Self.log.notice("generate: begin (first call also materializes weights on the GPU)")
                do {
                    let stream = try pipeline.chatStream(
                        prompt: prompt,
                        temperature: temperature,
                        maxTokens: maxTokens
                    )
                    var count = 0
                    for try await delta in stream {
                        // Honor cancellation promptly: a discarded consumer stops generation.
                        if Task.isCancelled {
                            continuation.finish(throwing: RuntimeError.cancelled)
                            return
                        }
                        if count == 0 { Self.log.notice("generate: first token received ✓") }
                        count += 1
                        continuation.yield(Token(delta))
                    }
                    if Task.isCancelled {
                        continuation.finish(throwing: RuntimeError.cancelled)
                        return
                    }
                    Self.log.notice("generate: finished, \(count, privacy: .public) chunks")
                    // A final empty terminal token lets consumers finalize without awaiting stream end.
                    continuation.yield(Token("", isFinal: true))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: RuntimeError.cancelled)
                } catch {
                    Self.log.error("generate: FAILED: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Structured output (validate → repair/retry → decode → outcome)

    /// A marker the prompt instructs the model to emit when the input does not fit the task. Mirrors
    /// `StubLLMRuntime`'s decline contract (design D2): a first-class typed decline, never a fabricated
    /// value. We accept either an explicit `{"applicable": false, ...}` or a `{"__declined__": "…"}`.
    private static let declineMarkerKey = "__declined__"

    public func structured<T: Decodable & Sendable>(
        _ request: LLMRequest,
        schema: StructuredSchema,
        as type: T.Type
    ) async throws -> StructuredOutcome<T> {
        try Task.checkCancellation()

        let budget = 3 // bounded repair/retry (first attempt + repairs), mirroring the stub
        var attempts = 0
        var lastFeedback: String? = nil

        while attempts < budget {
            try Task.checkCancellation()
            attempts += 1

            let prompt = Self.buildPrompt(
                base: request.prompt,
                schema: schema,
                repairFeedback: lastFeedback
            )
            // Greedy (low temperature) so structured output is as deterministic as the model allows.
            let genRequest = LLMRequest(
                prompt: prompt,
                parameters: GenerationParameters(maxTokens: request.parameters.maxTokens, temperature: 0)
            )
            let raw = try await generateText(genRequest)

            // 1) Decline detection: short-circuit to a typed decline.
            if let reason = Self.declineReason(in: raw) {
                return .declined(reason: reason)
            }

            // 2) Extract the JSON object from the (possibly chatty) model output.
            guard let jsonString = Self.extractJSONObject(from: raw),
                  let data = jsonString.data(using: .utf8) else {
                lastFeedback = "Your previous reply contained no JSON object. Reply with ONLY the JSON object."
                continue
            }

            // A decline can also arrive inside the extracted object.
            if let reason = Self.declineReason(in: jsonString) {
                return .declined(reason: reason)
            }

            // 3) Validate required keys (structural subset of JSON Schema, like the stub).
            guard Self.validate(jsonData: data, against: schema) else {
                let missing = Self.missingRequiredKeys(jsonData: data, against: schema)
                lastFeedback = "The JSON was missing required keys: \(missing.sorted().joined(separator: ", ")). "
                    + "Return ONLY a JSON object that includes every required key."
                continue
            }

            // 4) Decode into the target Swift type.
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                return .value(decoded)
            } catch {
                lastFeedback = "The JSON did not decode into the required type (\(error)). "
                    + "Fix the value types and return ONLY the corrected JSON object."
                continue
            }
        }

        throw RuntimeError.couldNotProduceValid(attempts: attempts)
    }

    // MARK: - Prompt building

    /// Build a JSON-instructing prompt: the base prompt, the schema, the strict output contract, and
    /// (on a repair attempt) feedback about what was wrong with the previous reply.
    private static func buildPrompt(base: String, schema: StructuredSchema, repairFeedback: String?) -> String {
        var p = base
        p += "\n\nJSON Schema (target shape \"\(schema.name)\"):\n"
        p += schema.json
        p += "\n\nReturn ONLY JSON matching this schema. Do not include any prose, code fences, or "
        p += "explanation. If the input does not fit, return {\"applicable\": false, \"reason\": \"…\"}."
        if let repairFeedback {
            p += "\n\nYour previous reply was rejected. \(repairFeedback)"
        }
        return p
    }

    // MARK: - JSON helpers (mirror StubLLMRuntime's validate/decline approach)

    /// If the raw text carries a decline — either `{"__declined__": "reason"}` or
    /// `{"applicable": false, "reason": "…"}` — return the reason.
    private static func declineReason(in raw: String) -> String? {
        guard let json = extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let reason = obj[declineMarkerKey] as? String { return reason }
        if let applicable = obj["applicable"] as? Bool, applicable == false {
            return (obj["reason"] as? String) ?? "The model declined: the input does not fit the task."
        }
        return nil
    }

    /// Structural validation: parse the JSON object and check it carries every key named in the
    /// schema's top-level `required` array (a pragmatic JSON-Schema subset, like the stub).
    private static func validate(jsonData: Data, against schema: StructuredSchema) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return false
        }
        let required = requiredKeys(fromSchemaJSON: schema.json)
        for key in required where value[key] == nil { return false }
        return true
    }

    /// The required keys absent from the JSON object (for repair feedback).
    private static func missingRequiredKeys(jsonData: Data, against schema: StructuredSchema) -> Set<String> {
        let required = requiredKeys(fromSchemaJSON: schema.json)
        guard let value = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return required
        }
        return required.filter { value[$0] == nil }
    }

    /// Extract the `required: [...]` string array from a JSON-Schema document string.
    private static func requiredKeys(fromSchemaJSON json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let required = obj["required"] as? [String] else { return [] }
        return Set(required)
    }

    /// Pull the first balanced top-level JSON object out of a model reply that may contain prose or a
    /// ```json code fence around the payload. Returns nil if no `{ … }` is found.
    private static func extractJSONObject(from raw: String) -> String? {
        guard let open = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < raw.endIndex {
            let c = raw[i]
            if escaped {
                escaped = false
            } else if c == "\\" && inString {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(raw[open...i])
                    }
                }
            }
            i = raw.index(after: i)
        }
        return nil
    }
}
