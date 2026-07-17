import Foundation

/// One spend record in the append-only CLOUD-video ledger (`ai-video-animation-generation`, design D3 —
/// the §3.8 `HandoffSpend` pattern reused, not reinvented). An admitted cloud video appends one; a launch
/// that fails after recording REMOVES it (refund), so the cap stays honest. `Codable` so the ledger
/// persists across a relaunch WITHIN the rolling window — a process restart cannot reset the daily budget.
/// MLX-free Core.
public struct VideoSpend: Codable, Equatable, Sendable {
    public let at: Date

    public init(at: Date) { self.at = at }
}

/// The pure ROLLING-24h rate/concurrency gate over an append-only spend ledger
/// (`ai-video-animation-generation`, design D3 — structurally the `HandoffBudget` pattern). `allows(now:)`
/// is a PURE predicate — `now` is an INPUT (deterministic) — so an autonomous loop physically cannot rack
/// up real spend and the window is unit-testable without a clock. The window is a SLIDING 24h count over
/// `now`, NOT a calendar-day reset, so a loop cannot dump N clips at 23:59 and N more at 00:01.
///
/// This is DISTINCT from the seam-owner's `PerDayVideoBudget` (a calendar-day counter): this slice's gate
/// is the rolling window the spec requires ("Rolling window cannot be gamed across midnight"). MLX-free Core.
public struct VideoBudget: Equatable, Sendable {
    /// The per-rolling-window call cap (`mediaVideoBudgetPerDay`). A `<= 0` cap never allows (cloud video
    /// effectively off).
    public let maxCallsPerWindow: Int
    /// At-most-N concurrent in-flight cloud videos (default 1 — one slow clip per loop step).
    public let maxConcurrent: Int
    /// The append-only spend records; in-flight is tracked separately.
    public private(set) var ledger: [VideoSpend]
    /// The count of admitted-but-not-yet-reaped generations.
    public private(set) var inFlight: Int

    /// The rolling window length: 24 hours.
    public static let window: TimeInterval = 24 * 60 * 60

    public init(maxCallsPerWindow: Int, maxConcurrent: Int = 1,
                ledger: [VideoSpend] = [], inFlight: Int = 0) {
        self.maxCallsPerWindow = maxCallsPerWindow
        self.maxConcurrent = max(1, maxConcurrent)
        self.ledger = ledger
        self.inFlight = inFlight
    }

    /// The number of spends inside the rolling 24h window ending at `now`.
    public func callsInLast24h(_ now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.window)
        return ledger.reduce(0) { $0 + ($1.at > cutoff ? 1 : 0) }
    }

    /// PURE predicate: under the rolling-window cap AND below the concurrency limit. `now` is an INPUT.
    public func allows(now: Date) -> Bool {
        guard maxCallsPerWindow > 0 else { return false }
        return callsInLast24h(now) < maxCallsPerWindow && inFlight < maxConcurrent
    }

    /// Spend a call: append the record + increment in-flight. (Called only AFTER `allows` passed AND the
    /// gen was admitted — the cap counts admitted generations, like the handoff per-day count.)
    public mutating func record(at: Date) {
        ledger.append(VideoSpend(at: at))
        inFlight += 1
    }

    /// A fire-and-forget gen is "done" → decrement in-flight (the ledger entry STAYS; it counts against the
    /// window cap). Only the concurrency count drops.
    public mutating func reap() {
        inFlight = max(0, inFlight - 1)
    }

    /// A launch that FAILED after recording didn't truly spend → remove the matching ledger entry (by `at`)
    /// and drop in-flight, leaving the cap unchanged from before the call (spec "A failed cloud launch
    /// refunds its spend").
    public mutating func refund(at: Date) {
        if let idx = ledger.lastIndex(where: { $0.at == at }) {
            ledger.remove(at: idx)
        }
        inFlight = max(0, inFlight - 1)
    }
}

// MARK: - Persistence seam (relaunch-surviving ledger)

/// The injectable persistence seam for the cloud-video ledger (`ai-video-animation-generation`, task 2.3 —
/// the §3.8 `HandoffLedgerStore` pattern). The ledger persists under Application Support so the rolling cap
/// survives a relaunch within the window. Tests inject an in-memory store. MLX-free Core.
public protocol VideoLedgerStore: Sendable {
    func load() -> [VideoSpend]
    func save(_ ledger: [VideoSpend])
}

/// The default no-disk store (tests / a fresh process). Records held in memory only.
public final class InMemoryVideoLedgerStore: VideoLedgerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: [VideoSpend]

    public init(_ ledger: [VideoSpend] = []) { self.ledger = ledger }

    public func load() -> [VideoSpend] {
        lock.lock(); defer { lock.unlock() }
        return ledger
    }

    public func save(_ ledger: [VideoSpend]) {
        lock.lock(); defer { lock.unlock() }
        self.ledger = ledger
    }
}

/// The durable JSON ledger store under Application Support (mirroring `DiskHandoffLedgerStore`). A read
/// failure yields an empty ledger (a fresh budget); a write failure is swallowed (the in-memory budget
/// still holds the spend) — cap honesty is best-effort persistence, never a thrown break into the loop.
/// MLX-free Core; its real IO is exercised by the user's build.
public final class DiskVideoLedgerStore: VideoLedgerStore, @unchecked Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    public init(fileURL: URL = DiskVideoLedgerStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/ThreeFingerSwitcher/media/video-ledger.json`.
    public static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("ThreeFingerSwitcher/media", isDirectory: true)
            .appendingPathComponent("video-ledger.json")
    }

    public func load() -> [VideoSpend] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([VideoSpend].self, from: data) else { return [] }
        return records
    }

    public func save(_ ledger: [VideoSpend]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(ledger)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: the in-memory budget still holds the spend; a persistence failure does not break
            // the loop (never thrown into the caller).
        }
    }
}

// MARK: - The mutable, thread-safe holder (the MediaVideoBudgeting conformer)

/// The mutable, thread-safe box the sink records spend against (`ai-video-animation-generation`, the §3.8
/// `HandoffBudgetBox` pattern). `VideoBudget` is a PURE value; this reference wrapper owns the single
/// mutable instance + its persistence so the `Sendable` sink can `consume`/`reap`/`refund` across an
/// `await` without data races. It CONFORMS to the seam-owner's `MediaVideoBudgeting` so it drops into the
/// EXISTING `MediaGenSink` / `MediaToolContributor` with NO seam change — the rolling-window budget is the
/// `videoProvider == .cloud` selection of the same protocol slot (the swap contract for the gate).
///
/// `hasRemaining(now:)` / `consume(now:)` satisfy `MediaVideoBudgeting` (the sink calls these); `reap` /
/// `refund` are the richer concurrency/refund operations the cloud runtime + contributor drive. MLX-free
/// Core.
public final class RollingVideoBudget: MediaVideoBudgeting, @unchecked Sendable {
    private let lock = NSLock()
    private var budget: VideoBudget
    private let store: VideoLedgerStore
    /// The cap is read LIVE (a settings change takes effect immediately) — the persisted
    /// `mediaVideoBudgetPerDay`, owned by `ai-full-potential-toggle`, CONSUMED via a closure (default 0).
    private let cap: @Sendable () -> Int
    private let maxConcurrent: Int

    public init(cap: @escaping @Sendable () -> Int = { 0 },
                maxConcurrent: Int = 1,
                store: VideoLedgerStore = InMemoryVideoLedgerStore()) {
        self.cap = cap
        self.maxConcurrent = max(1, maxConcurrent)
        self.store = store
        // Seed the ledger from disk so the rolling-window cap survives a relaunch (task 2.3).
        self.budget = VideoBudget(maxCallsPerWindow: cap(), maxConcurrent: self.maxConcurrent,
                                  ledger: store.load())
    }

    /// `MediaVideoBudgeting`: at least one more cloud video may run (under the rolling cap + concurrency).
    /// Rebuilds the pure budget with the LIVE cap so a settings bump takes effect at once.
    public func hasRemaining(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        syncCap()
        return budget.allows(now: now)
    }

    /// `MediaVideoBudgeting`: record one admitted cloud video as spent (after the budget check passed and
    /// the gen was approved). Increments in-flight + persists the ledger.
    public func consume(now: Date) {
        lock.lock(); defer { lock.unlock() }
        syncCap()
        budget.record(at: now)
        store.save(budget.ledger)
    }

    /// A fire-and-forget gen finished → decrement in-flight (the ledger entry stays).
    public func reap() {
        lock.lock(); defer { lock.unlock() }
        budget.reap()
    }

    /// A launch that failed after `consume` → refund: remove the entry recorded at `at` + drop in-flight,
    /// leaving the cap unchanged. Persists the corrected ledger.
    public func refund(at: Date) {
        lock.lock(); defer { lock.unlock() }
        budget.refund(at: at)
        store.save(budget.ledger)
    }

    /// A snapshot for assertions / tests.
    public func snapshot() -> VideoBudget {
        lock.lock(); defer { lock.unlock() }
        return budget
    }

    /// Rebuild the pure budget with the LIVE cap (preserving the ledger + in-flight), so a settings change
    /// to `mediaVideoBudgetPerDay` takes effect immediately without losing recorded spend.
    private func syncCap() {
        let live = cap()
        if live != budget.maxCallsPerWindow {
            budget = VideoBudget(maxCallsPerWindow: live, maxConcurrent: maxConcurrent,
                                 ledger: budget.ledger, inFlight: budget.inFlight)
        }
    }
}
