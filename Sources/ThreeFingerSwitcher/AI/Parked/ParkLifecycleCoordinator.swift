import Foundation

/// Bridges the pure `ParkLifecycle` decisions to the durable store: the (opt-in) auto-dismiss pass —
/// every dismissable session is removed FOREVER through the SAME authoritative `discard(_:)` path as a
/// manual dismiss — and the discard flow (remove from the store — completed side effects are NOT rolled
/// back). Keeps Core MLX-free.
///
/// Generation CANCELLATION is not owned here (`refactor-park-and-background-agents`): the per-session
/// `NotchSessionEngine` is the single cancellation owner — `ParkController` cancels via
/// `engines[id]?.cancelAll()` on every removal path. (The old `pending` task table here was dead in
/// production — only tests ever registered a task — so "discard cancels generation" could silently
/// no-op through this seam.)
final class ParkLifecycleCoordinator: @unchecked Sendable {
    private let store: ParkedSessionStore
    private let lifecycle: ParkLifecycle

    init(store: ParkedSessionStore, lifecycle: ParkLifecycle) {
        self.store = store
        self.lifecycle = lifecycle
    }

    /// Auto-dismiss every dismissable session FOREVER (the opt-in expiry — idle, fully seen, past the
    /// countdown): route each `lifecycle.dismissable(_:)` id through the EXISTING `discard(_:)` path
    /// verbatim. Returns the dismissed ids. Protected (`.active`/`.needsYou`) sessions, unseen results,
    /// and parked pending work are never touched. `now:` injected so the pass is deterministically
    /// testable.
    @discardableResult
    func runAutoDismissPass(now: Date) -> [AgentSessionID] {
        let ids = lifecycle.dismissable(store.all(), now: now)
        for id in ids { try? discard(id) }   // the authoritative removal path
        return ids
    }

    /// Evict the least-recently-updated idle session if over-cap; returns the evicted id (nil when none).
    @discardableResult
    func runEvictionPass(now: Date) -> AgentSessionID? {
        guard let victim = lifecycle.evictable(store.all(), now: now) else { return nil }
        try? store.remove(victim)
        return victim
    }

    /// Discard a parked session: remove the durable conversation + rail row. The caller
    /// (`ParkController`) cancels the live engine's generation first (a cancellation is NOT a failure —
    /// no `failed` badge is set). COMPLETED SIDE EFFECTS ARE NOT ROLLED BACK — a written event, a moved
    /// file, a launched process stays done; discard stops only FUTURE work.
    func discard(_ id: AgentSessionID) throws {
        try store.remove(id)
    }
}
