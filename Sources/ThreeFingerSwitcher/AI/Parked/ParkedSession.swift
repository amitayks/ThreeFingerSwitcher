import Foundation

/// The parked-session shared contract (blueprint §3.5 / design D1). This slice (`ai-parked-sessions`,
/// Wave 3) OWNS `ParkState` and `ParkedSession`; it consumes `AgentSessionID`/`AgentConversation`
/// (`ai-conversation-runtime`) and `ToolStepResult`/`ToolStepStatus` (`ai-tool-routing`) verbatim and
/// never redefines them. MLX-free Core (`swift test`-verified).
///
/// `ParkedSession` is the lightweight rail/scheduler ROW; the full `AgentConversation` lives in the
/// durable store keyed by the SAME `id`. `badgeCount` + `state` are the only two fields the badge view
/// reads. `Codable` because it persists alongside the conversation so the rail rebuilds on relaunch.

/// The observable state of a (possibly parked) session.
public enum ParkState: String, Codable, Equatable, Sendable {
    /// Foreground, in the canvas.
    case active
    /// Stashed at the notch home zone; may run in the background.
    case parked
    /// A dangerous write / required approval escalated to the foreground (badge + ambient glow).
    case needsYou
    /// Nothing pending — eligible for summarize-and-sleep + eviction.
    case idle
    /// The session's TASK has FINISHED (design D1 / Bug 3 terminal detection): the background advance
    /// reached a terminal `AgentLoopOutcome` (answered / cap / stopped-with-no-pending). A completed
    /// session is no longer runnable and is auto-dismissed FOREVER by the auto-dismiss pass (the same
    /// authoritative discard path as a manual dismiss). Distinct from `.idle` (which merely has nothing
    /// pending and could still receive a follow-up turn).
    case completed

    /// The non-evictable, non-dismissable states whose attention/escalation is protected (the foreground
    /// active session and an escalation waiting on the user). `parked`/`idle`/`completed` are eligible for
    /// lifecycle aging; `active`/`needsYou` are NEVER evicted or auto-dismissed (design D1/D7).
    var isProtectedFromAging: Bool {
        switch self {
        case .active, .needsYou:        return true
        case .parked, .idle, .completed: return false
        }
    }

    /// Whether the session's task has finished (design D1): a `.completed` row is terminal and is
    /// auto-dismissed forever on the next pass. Kept as a predicate so callers don't switch on the raw case.
    var isTerminal: Bool { self == .completed }
}

/// One lightweight rail/scheduler row for a session. The full transcript lives in the store under `id`.
public struct ParkedSession: Codable, Equatable, Identifiable, Sendable {
    /// SAME identity as `AgentConversation.id` (§3.1) — stable across park/restore.
    public var id: AgentSessionID
    /// Short, model- or first-turn-derived title, shown on the rail card.
    public var title: String
    public var state: ParkState
    /// Unseen results / needs-you items shown on the rail card.
    public var badgeCount: Int
    /// Scheduler hint for a timed/scheduled continuation (nil = runnable now).
    public var nextRunAt: Date?
    public var updatedAt: Date

    public init(id: AgentSessionID,
                title: String,
                state: ParkState,
                badgeCount: Int = 0,
                nextRunAt: Date? = nil,
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.state = state
        self.badgeCount = badgeCount
        self.nextRunAt = nextRunAt
        self.updatedAt = updatedAt
    }
}
