import Foundation

/// Automatic model-weight eviction (`model-idle-ttl-and-memory-pressure`): the PURE decision core.
///
/// The resident ~17 GB model previously had no automatic path back out of RAM — `evict()` fired only
/// on opt-in-off, a fleet plan, or the manual Settings button. This policy adds the two automatic
/// triggers the spec promises: memory pressure (fast path) and a quiescence-keyed idle TTL (backstop).
/// It is a pure function — time, activity, pressure, and quiescence are explicit inputs — so every
/// rule is deterministically testable without real weights or a real OS pressure source (the
/// `ResidencyPlanner`/`ConcurrencyBudget` idiom). `ModelManager` is the only executor of its verdicts.

/// The OS memory-pressure level, as reported by the injected observer (a thin
/// `DispatchSource.makeMemoryPressureSource` wrapper in the app; a settable fake in tests).
public enum MemoryPressureLevel: Comparable, Sendable {
    case nominal
    case warning
    case critical
}

/// A point-in-time view of whether the AI system is busy, pulled (not pushed) from the scheduler at
/// decision time. Same-actor (`@MainActor`) evaluation makes the evict-vs-just-scheduled ordering
/// deterministic: work scheduled after the snapshot lands after the evict and simply lazy-reloads.
public struct QuiescenceSnapshot: Equatable, Sendable {
    /// A generation turn is streaming right now (foreground or background). Blocks ALL eviction.
    public var turnInFlight: Bool
    /// Any live conversational surface is open — an `.active` chat session or an open voice
    /// conversation. Blocks TTL and warning-pressure eviction (a user mid-dialogue must not pay a
    /// reload between turns); only critical pressure overrides.
    public var foregroundSessionActive: Bool
    /// The earliest scheduled parked advance, if any (`ParkedSession.nextRunAt` minimum). Work due
    /// within the horizon blocks TTL/warning eviction — evicting just before a scheduled advance
    /// would thrash (evict → immediate reload).
    public var nextScheduledWork: Date?

    public init(turnInFlight: Bool = false,
                foregroundSessionActive: Bool = false,
                nextScheduledWork: Date? = nil) {
        self.turnInFlight = turnInFlight
        self.foregroundSessionActive = foregroundSessionActive
        self.nextScheduledWork = nextScheduledWork
    }
}

/// Why the policy chose to evict — carried into the log line (never user-facing UI; an automatic
/// evict is invisible-correct, the next request transparently reloads).
public enum EvictionReason: Equatable, Sendable {
    case criticalPressure
    case warningPressure
    case idleTTL
}

public enum EvictionVerdict: Equatable, Sendable {
    case keep
    case evict(EvictionReason)
}

public enum EvictionPolicy {

    /// Scheduled work due within this window counts as "imminent" and blocks TTL/warning eviction
    /// (an evict immediately followed by a scheduled reload is pure thrash).
    public static let scheduledWorkHorizon: TimeInterval = 5 * 60

    /// The warning-pressure IDLE FLOOR (`fix-evict-thrash-and-hot-path`): a resident large model
    /// keeps the system at sustained `.warning` as its NORMAL state, so warning-level eviction also
    /// requires no AI activity for this long. Without it, chronic warning + the coarse tick evicted
    /// between active turns → a 17 GB reload per turn → the bus-saturating reload storm the user
    /// felt as "late swipes and a laggy Mac". Reloads re-stamp activity, so every reload buys an
    /// automatic grace window. Critical stays immediate — a real emergency outranks comfort.
    public static let warningIdleFloor: TimeInterval = 5 * 60

    /// The pure verdict. Rules (design D1):
    /// - A turn or load in flight → ALWAYS keep (no trigger may interrupt work; re-evaluated next tick).
    /// - `.critical` pressure → evict even with a foreground session open (system health outranks an
    ///   open chat; the next message pays a visible, ordinary reload).
    /// - `.warning` pressure → evict only when FULLY quiescent AND idle ≥ `warningIdleFloor`
    ///   (chronic warning with a resident large model is normal operation, never a thrash trigger).
    /// - Idle TTL (`ttl > 0`) → evict when fully quiescent AND nothing has stamped activity for `ttl`.
    ///   `ttl == 0` disables ONLY this trigger — pressure triggers stay armed.
    /// - Fully quiescent = no turn, no foreground-active session, no scheduled work within
    ///   `scheduledWorkHorizon` (past-due counts as imminent: the driver just hasn't served it yet).
    public static func verdict(now: Date,
                               lastActivity: Date,
                               pressure: MemoryPressureLevel,
                               quiescence: QuiescenceSnapshot,
                               ttl: TimeInterval,
                               loadInFlight: Bool) -> EvictionVerdict {
        if quiescence.turnInFlight || loadInFlight { return .keep }
        if pressure == .critical { return .evict(.criticalPressure) }

        let scheduledImminent: Bool
        if let next = quiescence.nextScheduledWork {
            scheduledImminent = next.timeIntervalSince(now) <= scheduledWorkHorizon
        } else {
            scheduledImminent = false
        }
        let fullyQuiescent = !quiescence.foregroundSessionActive && !scheduledImminent

        if pressure == .warning {
            let idleEnough = now.timeIntervalSince(lastActivity) >= warningIdleFloor
            return (fullyQuiescent && idleEnough) ? .evict(.warningPressure) : .keep
        }
        if ttl > 0, fullyQuiescent, now.timeIntervalSince(lastActivity) >= ttl {
            return .evict(.idleTTL)
        }
        return .keep
    }
}
