import Foundation

/// Bridges the pure `ParkLifecycle` decisions to the durable store: the auto-dismiss pass (design D1 —
/// every terminal/idle-past-countdown session is DISMISSED FOREVER through the SAME authoritative
/// `discard(_:)` path as a manual dismiss) and the discard flow (cancel pending generation via `Task`
/// cancellation, remove from the store — completed side effects are NOT rolled back). Keeps Core MLX-free.
///
/// Per D1 the summarize-and-sleep flow (`ParkSleepRequesting` + a KV-drop seam) is RETIRED: an idle/terminal
/// session is removed forever, not slept.
final class ParkLifecycleCoordinator: @unchecked Sendable {
    private let store: ParkedSessionStore
    private let lifecycle: ParkLifecycle
    /// Live pending-generation tasks keyed by session — cancelled on discard.
    private var pending: [AgentSessionID: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init(store: ParkedSessionStore, lifecycle: ParkLifecycle) {
        self.store = store
        self.lifecycle = lifecycle
    }

    /// Register a session's pending generation task so a later discard can cancel it.
    func registerPending(_ id: AgentSessionID, task: Task<Void, Never>) {
        lock.lock(); pending[id] = task; lock.unlock()
    }

    /// Auto-dismiss every TERMINAL (`.completed`) and idle-past-countdown session FOREVER (design D1):
    /// route each `lifecycle.dismissable(_:)` id through the EXISTING `discard(_:)` path verbatim
    /// (cancelPending + store.remove). Returns the dismissed ids. Protected (`.active`/`.needsYou`)
    /// sessions are never touched. `now:` injected so the pass is deterministically testable.
    @discardableResult
    func runAutoDismissPass(now: Date) -> [AgentSessionID] {
        let ids = lifecycle.dismissable(store.all(), now: now)
        for id in ids { try? discard(id) }   // the authoritative removal path (Bug 1)
        return ids
    }

    /// Evict the least-recently-updated idle session if over-cap; returns the evicted id (nil when none).
    @discardableResult
    func runEvictionPass(now: Date) -> AgentSessionID? {
        guard let victim = lifecycle.evictable(store.all(), now: now) else { return nil }
        try? store.remove(victim)
        cancelPending(victim)
        return victim
    }

    /// Discard a parked session: cancel its pending generation (a cancellation is NOT a failure — no
    /// `failed` badge is set), remove the durable conversation + rail row. COMPLETED SIDE EFFECTS ARE
    /// NOT ROLLED BACK — a written event, a moved file, a launched process stays done; discard stops
    /// only FUTURE work.
    func discard(_ id: AgentSessionID) throws {
        cancelPending(id)
        try store.remove(id)
    }

    private func cancelPending(_ id: AgentSessionID) {
        lock.lock(); let task = pending.removeValue(forKey: id); lock.unlock()
        task?.cancel()
    }
}
