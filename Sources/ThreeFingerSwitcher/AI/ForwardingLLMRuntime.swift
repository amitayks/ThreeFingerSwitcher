import Foundation

/// A lazily-resolving `LLMRuntime` adapter (`wire-memory-skills`). The `SkillToolProvider` requires a
/// concrete `runtime` at construction so it can generate the skill's text result, but the live model is
/// loaded lazily through `ModelManager.runtime(requiring:)` and may not be resident when the tool
/// registry is built. This forwarder defers resolution to call time: each `generate`/`structured`/`chat`
/// resolves the resident runtime (kept resident between calls, so this is cheap) and forwards.
///
/// MLX-free Core — it depends only on the `LLMRuntime` seam and an injected `@Sendable` resolver, never on
/// Gemma/MLX. The resolver throws `RuntimeError` when no model is loaded; that surfaces as a clean
/// `.failed` step through the established taxonomy (never raw text, never a false "Done").
struct ForwardingLLMRuntime: LLMRuntime {
    /// Resolve the resident runtime for the given required modalities (typically `modelManager.runtime`).
    let resolve: @Sendable (Set<Modality>) async throws -> LLMRuntime

    /// Advertised capabilities. The forwarder claims text+vision so a vision-capable skill isn't filtered
    /// out before resolution; the real runtime enforces its own capabilities at resolve time.
    var capabilities: Set<Modality> { [.text, .vision] }

    func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
        let caps: Set<Modality> = request.image == nil ? [.text] : [.text, .vision]
        let resolve = self.resolve
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let runtime = try await resolve(caps)
                    for try await token in runtime.generate(request) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func structured<T: Decodable & Sendable>(
        _ request: LLMRequest,
        schema: StructuredSchema,
        as type: T.Type
    ) async throws -> StructuredOutcome<T> {
        let caps: Set<Modality> = request.image == nil ? [.text] : [.text, .vision]
        let runtime = try await resolve(caps)
        return try await runtime.structured(request, schema: schema, as: type)
    }

    func chat(_ request: LLMChatRequest) -> AsyncThrowingStream<Token, Error> {
        let needsVision = !request.effectiveImages.isEmpty
        let caps: Set<Modality> = needsVision ? [.text, .vision] : [.text]
        let resolve = self.resolve
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let runtime = try await resolve(caps)
                    for try await token in runtime.chat(request) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
