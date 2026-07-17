import Foundation

/// The park scheduler seam (blueprint §3.5 / design D2) — the SINGLE place the slot count is
/// interpreted, shaped so the batched runtime fills **K** slots at once as a pure drop-in. `now:` is an
/// INPUT (mirroring `DockHoverModel`) so decisions are deterministically testable. Consumes
/// `ToolStepResult`/`ToolStepStatus` (`ai-tool-routing`) verbatim. MLX-free Core.
public protocol ParkScheduler: Sendable {
    /// Which parked sessions to advance now, ordered by priority, up to `maxSlots`. Pure: result depends
    /// only on the parked set and `now`. The batched runtime decides `maxSlots`; the scheduler never
    /// assumes the count, so the one→K transition needs NO protocol change.
    func runnableSessions(now: Date, maxSlots: Int) -> [AgentSessionID]
    /// Feedback after a (batch) step settles the run and updates the session's rail row. There is NO
    /// terminal signal (`refactor-park-and-background-agents`): a settled `.done` is an unseen result
    /// (idle + badge), never a state that removes the session.
    func didAdvance(_ id: AgentSessionID, result: ToolStepResult)
    /// A dangerous write / required approval escalated this parked session to `.needsYou` (badge + glow).
    func escalate(_ id: AgentSessionID, reason: String)
    /// The current `ParkState` for `id`, read thread-safely from ANY thread (the background-autonomy runner
    /// reads it per step OFF the main actor). Defaults to `.active` (an unknown id is the foreground active
    /// session, never parked) so a conformer that does not track rows needs no override. The concrete
    /// `SerialParkScheduler` overrides it with a lock-guarded read of its live rows.
    func parkState(of id: AgentSessionID) -> ParkState
}

extension ParkScheduler {
    /// Default: foreground/`.active`. A conformer that tracks rows (the concrete scheduler) overrides this.
    func parkState(of id: AgentSessionID) -> ParkState { .active }
}

/// Shared, pure filter+order used by every concrete scheduler so the runnable contract is identical
/// regardless of `maxSlots`. A session is runnable iff it is `.parked` AND SCHEDULED — `nextRunAt` set
/// and arrived. A `.parked` row with NO `nextRunAt` is DORMANT (blocked on the user, e.g. a confirm-tier
/// pause) and is never runnable; `.needsYou` (blocked on the user), `.active`, and `.idle` are excluded.
/// Ordered oldest-waiting first: by `nextRunAt`, then `updatedAt`.
enum ParkRunnable {
    static func ordered(_ sessions: [ParkedSession], now: Date) -> [AgentSessionID] {
        sessions
            .filter { $0.state == .parked && $0.nextRunAt.map { $0 <= now } == true }
            .sorted { lhs, rhs in
                let l = lhs.nextRunAt ?? .distantPast
                let r = rhs.nextRunAt ?? .distantPast
                if l != r { return l < r }
                return lhs.updatedAt < rhs.updatedAt
            }
            .map(\.id)
    }
}

/// The v1 policy: at most ONE runnable session regardless of `maxSlots` (one active generation in this
/// slice). The batched runtime reserves slot 0 for the foreground active session; this scheduler fills
/// only the *remaining* parked slots — so `SerialParkScheduler` returning 1 + a foreground session is
/// two streams once batching lands, which is exactly the K-ready story. Backed by an injected snapshot
/// of the parked rows (the store/coordinator owns the rows; the scheduler is a pure read over them).
public final class SerialParkScheduler: ParkScheduler, @unchecked Sendable {
    /// The current parked rows, read at decision time. Mutated through `didAdvance`/`escalate` so the
    /// rail reflects the latest state. Serialized by the owning coordinator (main actor in practice).
    private var sessions: [AgentSessionID: ParkedSession]
    private let lock = NSLock()

    public init(sessions: [ParkedSession] = []) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    /// Replace/seed the row snapshot the scheduler reads (e.g. after a store reload).
    public func setSessions(_ rows: [ParkedSession]) {
        lock.lock(); defer { lock.unlock() }
        sessions = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    /// Current rows (for the store / lifecycle), ordered by `updatedAt` **ascending** (oldest first — the
    /// least-recently-used, the eviction candidate, leads).
    public func snapshot() -> [ParkedSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// The RAIL display order: rows **most-recently-used first** (`updatedAt` descending), so the last-used
    /// session sits right after the "+ New chat" card and the oldest trails at the far end. Distinct from
    /// `snapshot()` (oldest-first), which the store/lifecycle read.
    public func railSnapshot() -> [ParkedSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func runnableSessions(now: Date, maxSlots: Int) -> [AgentSessionID] {
        guard maxSlots > 0 else { return [] }
        lock.lock(); let rows = Array(sessions.values); lock.unlock()
        // At most one regardless of the caller's slot count — the v1 one-active-now policy.
        return Array(ParkRunnable.ordered(rows, now: now).prefix(1))
    }

    /// How long a failed background advance waits before the driver retries it.
    public static let failureRetryDelay: TimeInterval = 60

    public func didAdvance(_ id: AgentSessionID, result: ToolStepResult) {
        lock.lock(); defer { lock.unlock() }
        guard var row = sessions[id] else { return }
        switch result.status {
        case .done:
            // A new unseen result settled: idle + badge. NEVER a state that removes the session — the
            // old terminal (`.completed` → instant dismiss) classification deleted docked chats.
            row.updatedAt = Date()
            row.badgeCount += 1
            row.state = .idle
            row.nextRunAt = nil
        case .failed:
            // The failed badge carries the CLEAN headline only (the status already holds it); the row
            // re-parks with a scheduled retry so the failure is never silent and never a dead end.
            row.updatedAt = Date()
            row.state = .parked
            row.nextRunAt = Date().addingTimeInterval(Self.failureRetryDelay)
        case .awaitingApproval:
            // A paused step: a dangerous escalation already set `.needsYou` via `escalate` (never
            // downgraded here); a confirm-tier pause waits parked DORMANT (no next-run time → not
            // runnable) until the user brings the session back.
            if row.state != .needsYou {
                row.state = .parked
                row.nextRunAt = nil
            }
        case .declined:
            row.updatedAt = Date()
            row.state = .parked
            row.nextRunAt = nil
        }
        sessions[id] = row
    }

    public func escalate(_ id: AgentSessionID, reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard var row = sessions[id] else { return }
        row.state = .needsYou
        row.badgeCount = max(row.badgeCount, 1)
        row.updatedAt = Date()
        sessions[id] = row
    }

    /// The live park state for `id`, lock-guarded so the background-autonomy runner can read it OFF the
    /// main actor without trapping. An unknown id (the foreground active session, never parked) reads
    /// `.active` — the same semantics `ParkController.parkState(of:)` exposes.
    public func parkState(of id: AgentSessionID) -> ParkState {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]?.state ?? .active
    }
}
