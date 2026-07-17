import Foundation

/// The pure parked-session lifecycle: max-count eviction (idle-only) and the OPT-IN idle expiry
/// countdown. `now:` is injected so eviction-victim selection + dismissability are deterministic.
/// MLX-free Core.
///
/// There is NO terminal auto-dismiss (`refactor-park-and-background-agents`): a settled turn never
/// removes a session. Expiry defaults OFF (countdown 0 = never) and NEVER touches a session with unseen
/// results — deletion is otherwise the user's alone (discard/purge), with eviction as the soft bound.
struct ParkLifecycle {
    /// Soft target for the parked set; when exceeded, the least-recently-updated IDLE session is evicted.
    var maxParked: Int
    /// How long an `.idle`, fully-seen session may sit before it is auto-dismissed forever. `<= 0`
    /// DISABLES expiry entirely (the default — sessions never age out unless the user opts in).
    var autoDismissCountdown: TimeInterval

    init(maxParked: Int, autoDismissCountdown: TimeInterval) {
        self.maxParked = maxParked
        self.autoDismissCountdown = autoDismissCountdown
    }

    /// Sessions to AUTO-DISMISS FOREVER under the opt-in expiry: `.idle` rows with NO unseen results
    /// (`badgeCount == 0` — an unseen answer protects its session indefinitely) whose idle age exceeds
    /// the countdown. `.active`/`.needsYou` (protected) and `.parked` (pending work — streaming, dormant
    /// on an approval, or scheduled) are NEVER touched. A countdown of 0 (the default) dismisses nothing.
    /// Pure; `now:` injected. Each returned id is routed through the authoritative `discard(_:)` path.
    func dismissable(_ sessions: [ParkedSession], now: Date) -> [AgentSessionID] {
        guard autoDismissCountdown > 0 else { return [] }
        return sessions
            .filter { session in
                session.state == .idle
                    && session.badgeCount == 0
                    && now.timeIntervalSince(session.updatedAt) > autoDismissCountdown
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
