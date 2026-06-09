import Foundation

/// The seam for the agentic task layer (design D6; tasks phase 13). The executor routes a
/// side-effecting output (`.runTask` / `.sendTo`) to its task entirely through this protocol, so the
/// in-place pipeline and the task layer stay decoupled and both are testable headless.
///
/// REFINED in slice 4 from the thin `dispatch(...)` seam to a two-stage `prepare` → `execute`, which
/// makes the action-review/armed-confirmation state (design D6) first-class:
///
/// - `prepare(kind:resolvedPrompt:source:)` asks the model for a schema-targeted, validated, parsed
///   action via `runtime.structured(...)`. It maps a typed/affordance decline → `.declined`, a
///   validation-exhausted result → `.unavailable` (NO action), and a success → `.action` carrying the
///   preview `fields` and the prepared payload. It performs NO side effect.
/// - `execute(_:)` fires the side effect for a CONFIRMED `.action` only. The executor calls it after
///   the action-review is confirmed (when `confirmBeforeRun` is on) or directly (when the user has
///   turned review off — the stored value is honored, never overridden).
///
/// Discarding before `execute` leaves no side effect (the executor simply never calls it).
@MainActor
protocol TaskDispatching {
    /// Produce a `TaskReview` for `kind` from `resolvedPrompt` (the already-resolved template). The
    /// `source` is the fire-time provenance (app/URL/timestamp) recorded with saved/sent content.
    func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource) async -> TaskReview

    /// Fire the side effect for a confirmed review. A no-op for a non-`.action` review.
    /// - Throws: the task's failure (permission denied, sink failure, …) so the caller can surface it.
    func execute(_ review: TaskReview) async throws
}
