import Foundation

/// The `ApprovalGate` the conversational canvas drives via its canonical compass (design D7,
/// `ai-conversational-canvas` task 2.8): when the bounded route loop reaches a `.confirm`/`.dangerous`
/// tool step, the owning contributor `await`s a decision here, which suspends the loop and surfaces the
/// backing `TaskReview` to the canvas (DOWN = approve, RIGHT = skip — identical mnemonic to commit /
/// discard). The recognizer is UNTOUCHED; interpretation lives at the `AppCoordinator` seam, which calls
/// `approve()` / `skip()` on the executor, which forwards here.
///
/// It is a standalone `Sendable` class (NOT `@MainActor`) because `ApprovalGate.awaitDecision` is invoked
/// from `ToolRegistry.run` OFF the main actor inside the loop's task; it bridges back to the executor's
/// main-actor observable state through the injected `onAwait` closure (which sets `.awaitingApproval`).
/// A single in-flight pause at a time (the loop is sequential); a second `awaitDecision` before the first
/// resolves is defensive-resolved to `.skip` so the loop can never deadlock.
final class CanvasApprovalGate: ApprovalGate, @unchecked Sendable {
    /// Called (on the main actor) the instant a step needs approval, so the executor can transition to
    /// `.awaitingApproval(review)` and the canvas can render the review card.
    private let onAwait: @MainActor (TaskReview) -> Void
    /// Called (on the main actor) when a pending pause resolves (approve/skip/cancel), so the executor can
    /// leave `.awaitingApproval` (the loop resumes and re-publishes its next state).
    private let onResolve: @MainActor (ApprovalDecision) -> Void

    private let lock = NSLock()
    private var pending: CheckedContinuation<ApprovalDecision, Never>?

    init(onAwait: @escaping @MainActor (TaskReview) -> Void,
         onResolve: @escaping @MainActor (ApprovalDecision) -> Void = { _ in }) {
        self.onAwait = onAwait
        self.onResolve = onResolve
    }

    func awaitDecision(for review: TaskReview) async -> ApprovalDecision {
        if Task.isCancelled { return .cancel }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if pending != nil {
                // Defensive: a second pause before the first resolved — decline it so nothing deadlocks.
                lock.unlock()
                continuation.resume(returning: .skip)
                return
            }
            pending = continuation
            lock.unlock()
            Task { @MainActor in self.onAwait(review) }
        }
    }

    /// Resolve the pending pause (DOWN = `.approve`, RIGHT = `.skip`, a whole-canvas discard = `.cancel`).
    /// A no-op when nothing is awaiting. Returns whether a pause was actually resolved (so the seam can
    /// fall through to the normal commit/discard path when no step is pending).
    @discardableResult
    func resolve(_ decision: ApprovalDecision) -> Bool {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        guard let continuation else { return false }
        Task { @MainActor in self.onResolve(decision) }
        continuation.resume(returning: decision)
        return true
    }

    /// Whether a tool step is currently awaiting a decision.
    var isAwaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending != nil
    }
}
