import Foundation

/// The cloud-video per-day BUDGET cap (design D3) — a media-side mirror of the Claude-handoff cost gate
/// (`mediaVideoBudgetPerDay`, mirroring `ClaudeHandoffConfig`). Cloud video spends real money and leaves
/// the device, so it is `.dangerous` AND rate-capped: the sink enforces the cap BEFORE any network call,
/// so an exhausted budget is a clean `MediaError.cloudBudgetExhausted` with NO spend (never a silent
/// spend, never a silent refusal).
///
/// The flag `mediaVideoBudgetPerDay` is OWNED by `ai-full-potential-toggle` (§D1) — this slice CONSUMES it
/// via an injected closure (default 0 → no cloud video until configured). The per-day usage is tracked
/// against an injected `now:` so the rollover is deterministically testable. MLX-free Core.
public protocol MediaVideoBudgeting: Sendable {
    /// True iff at least one more cloud-video generation may run today (usage < the per-day cap).
    func hasRemaining(now: Date) -> Bool
    /// Record one cloud-video generation as spent (called AFTER the budget check passes and the gen is
    /// approved — the cap counts admitted generations, like the handoff per-day count).
    func consume(now: Date)
}

/// A simple per-calendar-day counter against `mediaVideoBudgetPerDay`. The cap closure is read live (so a
/// settings change takes effect immediately). Thread-safe; the day boundary is `Calendar.current`'s start
/// of day for `now`. A cap of 0 means cloud video is effectively off (no remaining, ever).
public final class PerDayVideoBudget: MediaVideoBudgeting, @unchecked Sendable {
    /// Reads the persisted `mediaVideoBudgetPerDay` (owned by `ai-full-potential-toggle`). Injected so
    /// this slice never defines the flag; default 0 (no cloud video until configured).
    private let cap: @Sendable () -> Int
    private let calendar: Calendar
    private let lock = NSLock()
    private var dayStart: Date?
    private var usedToday = 0

    public init(cap: @escaping @Sendable () -> Int = { 0 }, calendar: Calendar = .current) {
        self.cap = cap
        self.calendar = calendar
    }

    public func hasRemaining(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded(now)
        return usedToday < max(0, cap())
    }

    public func consume(now: Date) {
        lock.lock(); defer { lock.unlock() }
        rolloverIfNeeded(now)
        usedToday += 1
    }

    /// Reset the counter when `now` crosses into a new calendar day (the per-day rollover).
    private func rolloverIfNeeded(_ now: Date) {
        let start = calendar.startOfDay(for: now)
        if dayStart != start {
            dayStart = start
            usedToday = 0
        }
    }
}
