import Foundation

/// The result of one route turn. `.route` carries the model's decision (including a plain answer when
/// `tool == ""`); `.failed` carries a clean headline for an unexpected runtime failure; `.cancelled` is
/// a discard (not a failure).
enum RouteResult: Sendable {
    case route(ToolRoute)
    case failed(headline: String)
    case cancelled
}

/// Maps the `structured()` route turn's outcomes into a `RouteResult` (design D1). The router is the
/// reliability mechanism: a malformed or unknown route degrades to a plain answer (never a fabricated
/// tool call), a decline IS a first-class plain answer, and only a genuine runtime failure is `.failed`.
enum ToolRouter {

    static func route(context: RouteContext, candidates: [ToolDescriptor],
                      runtime: LLMRuntime, reasoning: Bool) async -> RouteResult {
        let prompt = RouteSchema.prompt(context: context, candidates: candidates)
        do {
            let outcome = try await runtime.structured(
                LLMRequest(prompt: prompt, reasoning: reasoning),
                schema: RouteSchema.schema, as: ToolRoute.self)
            switch outcome {
            case let .value(route):
                if route.isPlainAnswer { return .route(route) }
                if candidates.contains(where: { $0.name == route.tool }) { return .route(route) }
                // The model named a tool not in the candidate set (hallucinated) — degrade to a plain
                // answer rather than dispatch an unknown tool. The `widen_candidates` tool is the
                // legitimate path to more tools.
                return .route(ToolRoute(tool: "", rationale: route.rationale))
            case let .declined(reason):
                // The model judged that no tool fits — exactly the first-class "just talk" case.
                return .route(ToolRoute(tool: "", rationale: reason))
            }
        } catch let error as RuntimeError {
            switch error {
            case .cancelled:
                return .cancelled
            case .couldNotProduceValid:
                // A malformed route is never a fabricated tool call — fall back to a plain answer.
                return .route(ToolRoute(tool: ""))
            default:
                return .failed(headline: AIError.message(for: error).headline)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(headline: AIError.message(for: error).headline)
        }
    }
}
