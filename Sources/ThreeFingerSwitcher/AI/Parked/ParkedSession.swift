import Foundation

/// The parked-session shared contract (blueprint §3.5 / design D1). This slice (`ai-parked-sessions`,
/// Wave 3) OWNS `ParkState` and `ParkedSession`; it consumes `AgentSessionID`/`AgentConversation`
/// (`ai-conversation-runtime`) and `ToolStepResult`/`ToolStepStatus` (`ai-tool-routing`) verbatim and
/// never redefines them. MLX-free Core (`swift test`-verified).
///
/// `ParkedSession` is the lightweight rail/scheduler ROW; the full `AgentConversation` lives in the
/// durable store keyed by the SAME `id`. `badgeCount` + `state` are the only two fields the badge view
/// reads. `Codable` because it persists alongside the conversation so the rail rebuilds on relaunch.

/// The observable state of a (possibly parked) session. There is deliberately NO terminal state: a
/// conversational turn settling is never "task complete" (`refactor-park-and-background-agents` — the
/// old `.completed` → instant-auto-dismiss classification deleted chats docked mid-response). A session
/// is removed ONLY by user deletion/purge, the opt-in idle expiry, or the max-parked eviction.
public enum ParkState: String, Codable, Equatable, Sendable {
    /// Foreground, in the canvas.
    case active
    /// Stashed at the notch home zone; may run in the background. `nextRunAt == nil` means DORMANT
    /// (blocked on the user — e.g. a confirm-tier pause — never runnable until reactivated).
    case parked
    /// A dangerous write / required approval escalated to the foreground (badge + ambient glow).
    case needsYou
    /// Nothing pending — eligible for eviction and (opt-in) expiry.
    case idle

    /// Migration: rows persisted by older builds under the RETIRED terminal state ("completed") — or any
    /// unknown future raw value — decode as `.idle`, so no stored session ever fails to load or vanishes.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ParkState(rawValue: raw) ?? .idle
    }

    /// The non-evictable, non-dismissable states whose attention/escalation is protected (the foreground
    /// active session and an escalation waiting on the user). `parked`/`idle` are eligible for lifecycle
    /// aging; `active`/`needsYou` are NEVER evicted or auto-dismissed (design D1/D7).
    var isProtectedFromAging: Bool {
        switch self {
        case .active, .needsYou: return true
        case .parked, .idle:     return false
        }
    }
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
    /// When the background driver should next advance this session. nil = DORMANT: not scheduled, never
    /// runnable (a session waiting on the user, or one with nothing pending). The driver clears it when
    /// it serves the session so a second tick can never double-serve.
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
