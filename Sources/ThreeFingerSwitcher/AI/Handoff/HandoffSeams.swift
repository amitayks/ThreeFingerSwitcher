import Foundation

/// The narrow audit seam (`ai-claude-handoff`, design Decision 6). The contributor records exactly one
/// `AuditRecord` per `run` outcome through this protocol; the production conformer bridges to
/// `ai-background-autonomy`'s shared append-only `AuditLog` (one log, blueprint §3.7 — NOT a forked
/// handoff-only log). A no-op default + a recording test double keep the slice headless-testable.
/// MLX-free Core.
protocol HandoffAuditing: Sendable {
    func record(_ record: AuditRecord) async
}

/// The no-op default (a slice with no audit log wired yet). Records nowhere — used only as a safe
/// fallback; production always wires `AuditLogHandoffAuditing`.
struct NoopHandoffAudit: HandoffAuditing {
    init() {}
    func record(_ record: AuditRecord) async {}
}

/// The production audit bridge: records into the shared `AuditLog` (`ai-background-autonomy`). `record`
/// is non-blocking and infallible from the caller's view (the log swallows persistence failures and
/// surfaces them on its viewer, never throws into the loop).
struct AuditLogHandoffAuditing: HandoffAuditing {
    let log: AuditLog
    init(_ log: AuditLog) { self.log = log }
    func record(_ record: AuditRecord) async { log.record(record) }
}

/// The narrow escalation seam (`ai-claude-handoff`, design Decision 8). A dangerous handoff that needs
/// approval inside a PARKED session does NOT auto-run and does NOT silently wait — it raises
/// `ParkState.needsYou` via this seam so the user is pulled back to approve the spend. The production
/// conformer bridges to `ai-parked-sessions`' `ParkScheduler.escalate`. A no-op default + a recording
/// double keep the slice headless-testable. MLX-free Core.
protocol HandoffEscalating: Sendable {
    func escalate(_ sessionID: AgentSessionID, reason: String) async
}

/// The no-op default (an active-session-only context with no parked scheduler wired).
struct NoopHandoffEscalation: HandoffEscalating {
    init() {}
    func escalate(_ sessionID: AgentSessionID, reason: String) async {}
}

/// The production escalation bridge: raises the parked session's needs-you badge via `ParkScheduler`.
struct ParkSchedulerHandoffEscalation: HandoffEscalating {
    let scheduler: ParkScheduler
    init(_ scheduler: ParkScheduler) { self.scheduler = scheduler }
    func escalate(_ sessionID: AgentSessionID, reason: String) async {
        scheduler.escalate(sessionID, reason: reason)
    }
}
