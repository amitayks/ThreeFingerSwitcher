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
    /// Feedback after a (batch) step settles the run and updates the session's rail row. `taskComplete`
    /// is the bounded loop's terminal signal (`AgentLoopOutcome.isTaskComplete`): a `.done` step whose
    /// loop has FINISHED marks the row terminal (`.completed`) so the auto-dismiss pass removes it forever
    /// (design D1 / Bug 3); a `.done` that is merely an intermediate step keeps the old idle+badge behavior.
    func didAdvance(_ id: AgentSessionID, result: ToolStepResult, taskComplete: Bool)
    /// A dangerous write / required approval escalated this parked session to `.needsYou` (badge + glow).
    func escalate(_ id: AgentSessionID, reason: String)
}

extension ParkScheduler {
    /// Convenience for the common intermediate-step advance (no terminal completion). Lets existing
    /// callers / tests keep calling `didAdvance(_:result:)` while the terminal signal stays opt-in.
    func didAdvance(_ id: AgentSessionID, result: ToolStepResult) {
        didAdvance(id, result: result, taskComplete: false)
    }
}

/// Shared, pure filter+order used by every concrete scheduler so the runnable contract is identical
/// regardless of `maxSlots`. A session is runnable iff it is `.parked` and either has no `nextRunAt` or
/// its `nextRunAt` has arrived; `.needsYou` (blocked on the user), `.active`, `.idle`, and `.completed`
/// (terminal) are excluded. Ordered oldest-waiting first: by `nextRunAt` (nil first), then `updatedAt`.
enum ParkRunnable {
    static func ordered(_ sessions: [ParkedSession], now: Date) -> [AgentSessionID] {
        sessions
            .filter { $0.state == .parked && ($0.nextRunAt == nil || $0.nextRunAt! <= now) }
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

    /// Current rows (for the rail / lifecycle), ordered by `updatedAt`.
    public func snapshot() -> [ParkedSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    public func runnableSessions(now: Date, maxSlots: Int) -> [AgentSessionID] {
        guard maxSlots > 0 else { return [] }
        lock.lock(); let rows = Array(sessions.values); lock.unlock()
        // At most one regardless of the caller's slot count — the v1 one-active-now policy.
        return Array(ParkRunnable.ordered(rows, now: now).prefix(1))
    }

    public func didAdvance(_ id: AgentSessionID, result: ToolStepResult, taskComplete: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var row = sessions[id] else { return }
        switch result.status {
        case .done:
            // A new unseen result settled: bump the row. When the bounded loop has FINISHED
            // (`taskComplete`), the row is TERMINAL (`.completed`) so the auto-dismiss pass removes it
            // forever (design D1 / Bug 3); otherwise it's an intermediate step → idle+badge as before.
            row.updatedAt = Date()
            row.badgeCount += 1
            row.state = taskComplete ? .completed : .idle
        case .failed:
            // The failed badge carries the CLEAN headline only (the status already holds it); the row
            // surfaces failed without inventing a new error string here.
            row.updatedAt = Date()
            row.state = .parked
        case .awaitingApproval:
            // A dangerous step waiting on the user escalates (see `escalate`); a confirm step waits parked.
            row.state = .needsYou
        case .declined:
            row.updatedAt = Date()
            row.state = .parked
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
}
