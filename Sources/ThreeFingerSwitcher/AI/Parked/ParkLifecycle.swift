import Foundation

/// The pure parked-session lifecycle (design §7 / D1): max-count eviction (idle-only) and the
/// idle-/terminal auto-dismiss countdown. `now:` is injected so eviction-victim selection + dismissability
/// are deterministic. MLX-free Core.
///
/// Per D1 the old summarize-and-sleep flow (`ParkSleepRequesting` + `sleepable`) is RETIRED: a session
/// idle past its countdown — or one whose task COMPLETED — is DISMISSED FOREVER through the same
/// authoritative discard path as a manual dismiss, never summarized-and-slept.
struct ParkLifecycle {
    /// Soft target for the parked set; when exceeded, the least-recently-updated IDLE session is evicted.
    var maxParked: Int
    /// How long a non-protected `.parked`/`.idle` session may sit idle before it is AUTO-DISMISSED forever
    /// (design D1, one user-configurable countdown, default 300s). A `.completed` (terminal) row is
    /// dismissed immediately regardless of age.
    var autoDismissCountdown: TimeInterval

    init(maxParked: Int, autoDismissCountdown: TimeInterval) {
        self.maxParked = maxParked
        self.autoDismissCountdown = autoDismissCountdown
    }

    /// Sessions to AUTO-DISMISS FOREVER (design D1): every TERMINAL (`.completed`) row regardless of age,
    /// PLUS every non-protected (`.parked`/`.idle`) row whose idle age exceeds `autoDismissCountdown`.
    /// `.active`/`.needsYou` are NEVER touched (the user's attention / a pending escalation is protected).
    /// Pure; `now:` injected. Each returned id is routed through the authoritative `discard(_:)` path.
    func dismissable(_ sessions: [ParkedSession], now: Date) -> [AgentSessionID] {
        sessions
            .filter { session in
                if session.state.isProtectedFromAging { return false }   // active/needsYou never dismissed
                if session.state.isTerminal { return true }              // completed → dismiss now
                return now.timeIntervalSince(session.updatedAt) > autoDismissCountdown
            }
            .map(\.id)
    }

    /// When the parked set exceeds `maxParked`, the least-recently-updated `.idle` session to evict —
    /// or `nil` when nothing is over-cap or no `.idle` victim exists (an all-non-idle set is never
    /// force-evicted; the cap is a soft target, never a hard refusal that loses a conversation).
    /// `.active`/`.needsYou`/thinking-`.parked` are NEVER chosen (the user's attention is protected).
    func evictable(_ sessions: [ParkedSession], now: Date) -> AgentSessionID? {
        guard sessions.count > maxParked else { return nil }
        return sessions
            .filter { $0.state == .idle }
            .min { $0.updatedAt < $1.updatedAt }?
            .id
    }
}
