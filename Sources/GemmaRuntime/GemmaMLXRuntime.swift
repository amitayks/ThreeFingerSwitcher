// GemmaMLXRuntime — the real, in-process Gemma 4 conformer of Core's `LLMRuntime` seam.
//
// It wraps a `Gemma4Pipeline` (from the `Gemma4Swift` package → mlx-swift) and bridges it to the
// Core protocol that all feature code depends on. This file links MLX (Metal shaders), so it lives
// in the isolated `GemmaRuntime` target and is only ever built via `xcodebuild` — Core and the test
// target never see it (design D1/D7).

import CoreGraphics
import Foundation
import ImageIO
import os
import ThreeFingerSwitcherCore
import Gemma4Swift
import MLX
import MLXRandom
import MLXLMCommon

/// In-process Gemma 4 (MLX) implementation of `LLMRuntime`.
///
/// CHANNEL-TAGGED STREAMING. Gemma 4 has a thinking ("thought") channel and a final ("response") channel,
/// delimited in-band by control tokens (`<|think|>`, `<|channel>` + a "thought"/"response" name, `<channel|>`).
/// This runtime classifies every generated token into Core's `TokenChannel` (`.thinking`/`.response`) and
/// emits `Token(text, channel:)` so the executor can split the two — streaming `.thinking` into the canvas's
/// collapsible section while committing only `.response`. Channel CONTROL tokens are consumed and yield no
/// visible text. Classification needs token-LEVEL access, which `Gemma4Pipeline.chatStream` (it yields decoded
/// `String` deltas, no tokenId) cannot provide — so any request that needs channels routes through a manual
/// generate loop with a per-token classifier (`ChannelClassifier`, replicating `Gemma4TokenFilter.filterToken`).
///
/// ENABLING THINKING. Gemma 4 does NOT think by default: its chat template, at the generation prompt, emits an
/// empty closed thought channel (`<|channel>thought\n<channel|>`) that suppresses reasoning UNLESS the template
/// variable `enable_thinking` is true (which also injects `<|think|>` into the leading system turn). So when a
/// request asks for reasoning we pass `["enable_thinking": true]` through `applyChatTemplate(...additionalContext:)`;
/// otherwise we leave it off and the model produces response-only.
///
/// ROUTING. A plain text request with reasoning OFF keeps the fast `Gemma4Pipeline.chatStream(...)` path
/// unchanged (every chunk is `.response`). A request that is EITHER vision (image present) OR reasoning ON runs
/// the manual loop. The manual loop covers both text (no image) and vision (image → `Gemma4ImageProcessor` →
/// pixelValues + 280 soft tokens; one `<|image|>` placeholder expanded to `boi + image×280 + eoi`;
/// `pendingPixelValues` set on the `Gemma4MultimodalLLMModel`) on the SEPARATE, lazily-loaded multimodal
/// `ModelContainer` — `chatStream` has no image-bearing or token-level entry point. A vision-capable runtime thus
/// holds two resident graphs (text pipeline + multimodal container), acceptable per the spec's high-end-hardware /
/// ample-unified-memory target. When reasoning is OFF on the manual path (a vision command with reasoning off),
/// thinking tokens are dropped (response-only, like `Gemma4TokenFilter` mode `.disabled`). Video/audio are out of
/// scope for v1: `LLMRequest` carries at most one optional PNG `image`, so only the image branch runs.
///
/// CANCELLATION: discarding the consumer stops token DELIVERY and surfaces `.cancelled` promptly. For the
/// fast `chatStream` text path it does NOT tear down the underlying MLX generation — the vendored
/// `Gemma4Pipeline.chatStream` wrapper task doesn't forward stream termination, so GPU work runs on to
/// `maxTokens` in the background. (A future fix would drive the `ChatSession` stream directly, which cancels
/// properly.) The manual loop checks `Task.isCancelled` between decode steps and finishes with `.cancelled`
/// promptly (throwing `RuntimeError.cancelled`).
///
/// `@unchecked Sendable`: the wrapped `@MainActor`-isolated pipeline (and the lazily-loaded multimodal
/// container) are only ever touched on the main actor (every hop into them is `@MainActor`); the pipeline
/// reference is immutable after init and the vision state is mutated only under `@MainActor`.
public final class GemmaMLXRuntime: LLMRuntime, @unchecked Sendable {

    /// The MLX-backed pipeline. `@MainActor` per `Gemma4Pipeline`'s own isolation.
    private let pipeline: Gemma4Pipeline

    /// v1: text + vision (image-only). The text path runs on `pipeline.chatStream`; the vision path runs
    /// on a separate lazily-loaded multimodal `ModelContainer` (see the type doc).
    public let capabilities: Set<Modality> = [.text, .vision]

    /// The on-disk model directory resolved + loaded during `prepare(...)`. The vision path lazily loads
    /// its own multimodal container from these SAME already-downloaded files. `nil` until a successful
    /// `prepare`; a vision request before that throws `.modelMissing`. Touched only on the main actor.
    @MainActor private var loadedModelDir: URL?

    /// The lazily-loaded, resident multimodal container for the vision path (built on first vision request
    /// from `loadedModelDir`, then cached). Separate from the text pipeline because `Gemma4Pipeline` loads
    /// the text-only graph and keeps its container private. Touched only on the main actor.
    @MainActor private var multimodalContainer: ModelContainer?

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
            // Remember the resolved on-disk dir so the vision path can lazily load its OWN multimodal
            // container from these same files later (the text pipeline keeps its container private).
            loadedModelDir = modelDir
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
        let reasoning = request.reasoning
        let pipeline = self.pipeline

        let image = request.image

        return AsyncThrowingStream { continuation in
            // Manual-loop path: any request that needs channel classification — EITHER vision (the text
            // pipeline's `chatStream` is text-only AND has no token-level entry point) OR reasoning ON
            // (channels are delimited by in-band control tokens only visible at the token level). Streams
            // channel-tagged tokens live; `enableThinking` is the request's `reasoning` flag (vision with
            // reasoning off is response-only). The image's bytes, if any, are captured by value (PNG `Data`).
            if needsVision || reasoning {
                let task = Task { @MainActor in
                    await self.runManual(image: image, prompt: prompt, temperature: temperature,
                                         maxTokens: maxTokens, enableThinking: reasoning,
                                         continuation: continuation)
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            // Fast path: plain text, no reasoning → keep `chatStream` unchanged (every chunk is `.response`).
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

    // MARK: - Channel classification (replicates Gemma4TokenFilter.filterToken)

    /// A small per-token state machine that splits Gemma 4's in-band channels (thinking vs response) the
    /// SAME way the vendored `Gemma4TokenFilter.filterToken` does — but instead of filtering, it CLASSIFIES:
    /// for every generated token it returns `(visibleText, channel)`, where channel-control tokens
    /// (`<|think|>`, `<|channel>`, `<channel|>`) and the channel-name text (`thought`/`response`) yield NO
    /// visible text. The model emits `<|channel>` then a name selecting the channel; tokens inside `thought`
    /// are `.thinking`, inside `response` (or outside any channel) are `.response`.
    ///
    /// `dropThinking`: when true (reasoning OFF on the manual path, e.g. a vision command with reasoning
    /// off), thinking-channel text is suppressed (returned empty) so only the response survives — exactly
    /// `Gemma4TokenFilter` mode `.disabled`. When false, thinking text rides through tagged `.thinking`.
    /// Reference: `Gemma4TokenFilter.filterToken` and `Gemma4Processor.{thinkTokenId,channelStartTokenId,
    /// channelEndTokenId}`.
    struct ChannelClassifier {
        private enum Channel { case none, thinking, response, detecting }
        private var channel: Channel = .none
        private var pendingName: String = ""
        let dropThinking: Bool

        init(dropThinking: Bool) { self.dropThinking = dropThinking }

        /// Classify one generated token → `(visibleText, channel)`. `visibleText` is "" for control/name
        /// tokens (and for thinking tokens when `dropThinking`); `channel` is the channel the token sits in.
        mutating func classify(tokenId: Int32, text: String) -> (text: String, channel: TokenChannel) {
            // Channel-control tokens — consumed, no visible text.
            if tokenId == Gemma4Processor.channelStartTokenId {
                channel = .detecting          // <|channel> — next text names the channel
                pendingName = ""
                return ("", .response)
            }
            if tokenId == Gemma4Processor.channelEndTokenId {
                channel = .none               // <channel|> — close the current channel
                return ("", .response)
            }
            if tokenId == Gemma4Processor.thinkTokenId {
                return ("", .response)        // <|think|> — enables thinking; itself invisible
            }

            // Detecting the channel name ("thought" vs "response") right after <|channel>.
            if channel == .detecting {
                pendingName += text
                if pendingName.contains("thought") {
                    channel = .thinking; pendingName = ""; return ("", .thinking)
                } else if pendingName.contains("response") {
                    channel = .response; pendingName = ""; return ("", .response)
                }
                // Accumulated too much without a match → treat as response (mirrors the filter's >20 guard).
                if pendingName.count > 20 {
                    channel = .response
                    let buffered = pendingName
                    pendingName = ""
                    return (buffered, .response)
                }
                return ("", .response)        // still buffering the name
            }

            // Inside a channel (or none → response).
            switch channel {
            case .thinking:
                return (dropThinking ? "" : text, .thinking)
            case .response, .none:
                return (text, .response)
            case .detecting:
                return ("", .response)        // unreachable
            }
        }
    }

    // MARK: - Manual generate loop (vision and/or reasoning) — channel-tagged streaming

    /// Number of soft tokens a single image expands to (the CLI's `numImageTokens`; `Gemma4ImageProcessor`
    /// also defaults to 280 via `maxSoftTokens`). Kept here so the placeholder expansion and the processor
    /// agree on one constant.
    private static let numImageTokens = 280

    /// Lazily build (and cache) the resident multimodal container from the SAME already-downloaded files
    /// that `prepare(...)` loaded. Mirrors the CLI's `loadLocalMultimodalModel(path:)`:
    /// `register(multimodal: true)` + `loadModelContainer(from:using:)` with the pipeline's own tokenizer
    /// loader. Throws `.modelMissing` if no model has been prepared yet. The container is multimodal-capable
    /// but also serves text-only manual generation (no image → no pixel injection → pure text decode).
    @MainActor
    private func ensureMultimodalContainer() async throws -> ModelContainer {
        if let multimodalContainer { return multimodalContainer }
        guard let dir = loadedModelDir else {
            Self.log.error("manual: no model prepared — cannot load multimodal container")
            throw RuntimeError.modelMissing
        }
        Self.log.notice("manual: loading multimodal container (first manual-path request; this is heavy)…")
        do {
            await Gemma4Registration.register(multimodal: true)
            let container = try await loadModelContainer(from: dir, using: Gemma4TokenizerLoader())
            multimodalContainer = container
            Self.log.notice("manual: multimodal container ready ✓")
            return container
        } catch is CancellationError {
            throw RuntimeError.cancelled
        } catch let runtime as RuntimeError {
            throw runtime
        } catch {
            // Map any vendor/OS load failure into the shared taxonomy at this boundary (design D6).
            Self.log.error("manual: multimodal load FAILED: \(String(describing: error), privacy: .public)")
            throw RuntimeError.modelLoadFailed(detail: String(describing: error))
        }
    }

    /// Run the manual (vision and/or reasoning) generation end-to-end, pumping channel-tagged tokens into
    /// `continuation` LIVE as they are produced. Any thrown error is mapped to `RuntimeError` and used to
    /// finish the stream; cancellation is NOT a failure (it finishes with `.cancelled`).
    @MainActor
    private func runManual(
        image: Data?,
        prompt: String,
        temperature: Float,
        maxTokens: Int,
        enableThinking: Bool,
        continuation: AsyncThrowingStream<Token, Error>.Continuation
    ) async {
        do {
            try await manualGenerate(
                image: image, prompt: prompt, temperature: temperature, maxTokens: maxTokens,
                enableThinking: enableThinking, continuation: continuation)
            if Task.isCancelled {
                continuation.finish(throwing: RuntimeError.cancelled)
                return
            }
            // A final empty terminal token lets consumers finalize without awaiting stream end.
            continuation.yield(Token("", isFinal: true))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: RuntimeError.cancelled)
        } catch let runtime as RuntimeError {
            Self.log.error("manual: FAILED: \(String(describing: runtime), privacy: .public)")
            continuation.finish(throwing: runtime)
        } catch {
            Self.log.error("manual: FAILED: \(String(describing: error), privacy: .public)")
            continuation.finish(throwing: RuntimeError.modelLoadFailed(detail: String(describing: error)))
        }
    }

    /// The manual decode path used for vision and/or reasoning. Builds + (for vision) expands the multimodal
    /// prompt, optionally injects pixels, then runs a greedy/sampled generate loop feeding EVERY generated
    /// token through `ChannelClassifier` and yielding `Token(visibleText, channel:)`. Replicates the CLI's
    /// Describe loop but keeps token-level access so channels can be classified. `enableThinking` flips the
    /// chat template's `enable_thinking` (Gemma 4 does NOT think by default — see the type doc) AND tells the
    /// classifier whether to keep (`true`) or drop (`false`) thinking text. Honors Task cancellation between
    /// decode steps (throws `RuntimeError.cancelled`).
    @MainActor
    private func manualGenerate(
        image: Data?,
        prompt: String,
        temperature: Float,
        maxTokens: Int,
        enableThinking: Bool,
        continuation: AsyncThrowingStream<Token, Error>.Continuation
    ) async throws {
        if Task.isCancelled { throw RuntimeError.cancelled }
        Self.log.notice("manual: begin (image \(image?.count ?? 0, privacy: .public) bytes, thinking=\(enableThinking, privacy: .public))")

        let container = try await ensureMultimodalContainer()
        if Task.isCancelled { throw RuntimeError.cancelled }

        // 1) For a vision request, PNG `Data` → CGImage → pixelValues [1, C, H, W]. Map a decode failure to
        //    a clean taxonomy case (never raw OS text in a headline — the detail rides as opt-in copyable).
        let numImageTokens = Self.numImageTokens
        var pixelValues: MLXArray? = nil
        if let image {
            guard let source = CGImageSourceCreateWithData(image as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                Self.log.error("manual: could not decode image bytes")
                throw RuntimeError.modelLoadFailed(detail: "Could not decode the captured image (PNG).")
            }
            do {
                pixelValues = try Gemma4ImageProcessor.processImage(cgImage, maxSoftTokens: numImageTokens)
            } catch {
                Self.log.error("manual: image preprocessing FAILED: \(String(describing: error), privacy: .public)")
                throw RuntimeError.modelLoadFailed(detail: String(describing: error))
            }
            Self.log.notice("manual: image preprocessed → \(pixelValues!.shape.description, privacy: .public)")
        }
        if Task.isCancelled { throw RuntimeError.cancelled }

        // 2) Build the chat-templated prompt. For vision, prepend one "<|image|>" placeholder. To enable
        //    reasoning we pass `enable_thinking` through the template's additionalContext — Gemma 4's chat
        //    template otherwise injects an empty closed thought channel that suppresses thinking (see type doc).
        let content = image != nil ? "<|image|>\n" + prompt : prompt
        let messages: [[String: any Sendable]] = [["role": "user", "content": content]]
        let additionalContext: [String: any Sendable] = ["enable_thinking": enableThinking]
        let baseTokenIds: [Int] = try await container.perform { context in
            try context.tokenizer.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: additionalContext)
        }

        // 3) For vision, expand the single image placeholder to boi + image_token×N + eoi (like the CLI).
        let imageTokenId = Int(Gemma4Processor.imageTokenId)
        let boiTokenId = Int(Gemma4Processor.boiTokenId)
        let eoiTokenId = Int(Gemma4Processor.eoiTokenId)
        var expanded: [Int] = []
        if image != nil {
            expanded.reserveCapacity(baseTokenIds.count + numImageTokens + 2)
            for tid in baseTokenIds {
                if tid == imageTokenId {
                    expanded.append(boiTokenId)
                    for _ in 0 ..< numImageTokens { expanded.append(imageTokenId) }
                    expanded.append(eoiTokenId)
                } else {
                    expanded.append(tid)
                }
            }
        } else {
            expanded = baseTokenIds
        }
        let inputIds = MLXArray(expanded.map { Int32($0) })
        Self.log.notice("manual: \(expanded.count, privacy: .public) input tokens")
        if Task.isCancelled { throw RuntimeError.cancelled }

        // 4) For vision, inject the pixels onto the multimodal model so the forward pass scatters them at the
        //    image token positions. Captured `nonisolated(unsafe)` to cross into the container's closure (the
        //    MLXArray is not Sendable but is used single-threaded here, mirroring the CLI).
        if let pv = pixelValues {
            nonisolated(unsafe) let finalPixelValues = pv
            await container.perform { context in
                if let model = context.model as? Gemma4MultimodalLLMModel {
                    model.pendingPixelValues = finalPixelValues
                }
            }
        }

        // 5) Manual generate loop: prefill, then autoregressive decode → channel-classified tokens, yielded
        //    LIVE. Greedy at temperature≈0, sampled otherwise. `dropThinking` is the inverse of reasoning —
        //    response-only when reasoning is off (mirrors `Gemma4TokenFilter` mode `.disabled`).
        nonisolated(unsafe) let capturedInputIds = inputIds
        let cappedMaxTokens = max(1, maxTokens)
        let eosTokenIds = Gemma4Processor.eosTokenIds
        let dropThinking = !enableThinking
        // The continuation is Sendable; yielding from inside `perform` streams tokens as they decode.
        nonisolated(unsafe) let sink = continuation

        try await container.perform { context in
            let params = GenerateParameters(maxTokens: cappedMaxTokens, temperature: temperature, topP: 0.95)
            let cache = context.model.newCache(parameters: params)

            // Prefill the full prompt; take argmax of the last position as the first generated token.
            let prefill = context.model(capturedInputIds.reshaped(1, -1), cache: cache)
            var nextToken = argMax(prefill[0..., prefill.dim(1) - 1, 0...], axis: -1).item(Int32.self)

            var classifier = ChannelClassifier(dropThinking: dropThinking)
            var visibleResponseEmitted = 0
            // Budget generously above the visible cap for in-band thinking/channel tokens (mirrors the CLI's
            // headroom). Stop on EOS or once the VISIBLE RESPONSE budget is reached (thinking doesn't count).
            let hardCap = cappedMaxTokens * 3
            for _ in 0 ..< hardCap {
                if Task.isCancelled { throw RuntimeError.cancelled }
                if eosTokenIds.contains(nextToken) { break }

                let decoded = context.tokenizer.decode(tokenIds: [Int(nextToken)])
                let (visible, channel) = classifier.classify(tokenId: nextToken, text: decoded)
                if !visible.isEmpty {
                    sink.yield(Token(visible, channel: channel))
                    if channel == .response { visibleResponseEmitted += 1 }
                }
                if visibleResponseEmitted >= cappedMaxTokens { break }

                let nextInput = MLXArray([nextToken]).reshaped(1, 1)
                let output = context.model(nextInput, cache: cache)
                if temperature <= 0.01 {
                    nextToken = argMax(output[0..., 0, 0...], axis: -1).item(Int32.self)
                } else {
                    let logits = output[0..., 0, 0...] / temperature
                    let probs = softmax(logits, axis: -1)
                    // Qualify `MLX.log` — the unqualified `log` collides with this type's static `log`
                    // (`Logger`) property, which the compiler would otherwise resolve to.
                    nextToken = MLXRandom.categorical(MLX.log(probs)).item(Int32.self)
                }
            }
        }

        if Task.isCancelled { throw RuntimeError.cancelled }
        Self.log.notice("manual: finished ✓")
    }

    // MARK: - Response-only text collection

    /// Collect a generation into a single string of the FINAL ANSWER ONLY — `.response`-channel text,
    /// dropping any `.thinking`. The protocol's default `generateText` concatenates EVERY token's text
    /// (thinking included), which would feed the model's reasoning into JSON extraction; structured output
    /// must parse only the response, so we override here. (For a non-reasoning request this is identical to
    /// the default — every chunk is already `.response`.)
    public func generateText(_ request: LLMRequest) async throws -> String {
        var out = ""
        for try await token in generate(request) where token.channel == .response {
            out += token.text
        }
        return out
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
            // Propagate the caller's `image`/`reasoning` so a vision or reasoning structured request still
            // routes through the right path. `generateText` (overridden above) returns RESPONSE-channel text
            // ONLY — so JSON is extracted from the final answer, never from thinking (which may contain
            // braces that would otherwise mislead `extractJSONObject`).
            let genRequest = LLMRequest(
                prompt: prompt,
                image: request.image,
                parameters: GenerationParameters(maxTokens: request.parameters.maxTokens, temperature: 0),
                reasoning: request.reasoning
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
