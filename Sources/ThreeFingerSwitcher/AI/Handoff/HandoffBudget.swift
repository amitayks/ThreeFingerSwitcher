import Foundation

/// One spend record in the append-only handoff ledger (`ai-claude-handoff`, design Decision 5). A
/// successful (or in-flight) handoff appends one; a launch that throws after recording removes it
/// (refund), so the cap stays honest. `Codable` so the ledger persists across a relaunch within the
/// rolling window — a process restart cannot reset the daily budget. MLX-free Core.
struct HandoffSpend: Codable, Equatable, Sendable {
    let at: Date
    let skillID: String?

    init(at: Date, skillID: String? = nil) {
        self.at = at
        self.skillID = skillID
    }
}

/// The pure rate/budget gate over an append-only spend ledger (`ai-claude-handoff`, design Decision 5).
/// `allows(now:)` is a PURE predicate — `now` is an INPUT (deterministic, `DockHoverModel`-style) — so an
/// autonomous agent loop physically cannot rack up real spend and the window is unit-testable without a
/// clock. The window is **rolling 24h** (a sliding count over `now`), NOT a calendar-day reset, so a loop
/// cannot dump N calls at 23:59 and N more at 00:01. MLX-free Core.
struct HandoffBudget: Equatable, Sendable {
    /// The resolved per-window cap (a skill cap or the global default; 0 means "disabled" — see the
    /// contributor's resolution). A `<= 0` cap never allows.
    let maxCallsPerDay: Int
    /// At-most-N in-flight handoffs (v1 default 1). v1 reaps immediately on a successful open, so this
    /// really means "one handoff per loop step" (design §6 / Q3).
    let maxConcurrent: Int
    /// The append-only spend records; in-flight is tracked separately.
    private(set) var ledger: [HandoffSpend]
    /// The count of opened-but-not-yet-reaped handoffs.
    private(set) var inFlight: Int

    /// The rolling window length: 24 hours.
    static let window: TimeInterval = 24 * 60 * 60

    init(maxCallsPerDay: Int, maxConcurrent: Int = 1,
         ledger: [HandoffSpend] = [], inFlight: Int = 0) {
        self.maxCallsPerDay = maxCallsPerDay
        self.maxConcurrent = max(1, maxConcurrent)
        self.ledger = ledger
        self.inFlight = inFlight
    }

    /// The number of spends inside the rolling 24h window ending at `now`.
    func callsInLast24h(_ now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.window)
        return ledger.reduce(0) { $0 + ($1.at > cutoff ? 1 : 0) }
    }

    /// PURE predicate: under the rolling-window cap AND below the concurrency limit. `now` is an INPUT.
    func allows(now: Date) -> Bool {
        guard maxCallsPerDay > 0 else { return false }
        return callsInLast24h(now) < maxCallsPerDay && inFlight < maxConcurrent
    }

    /// Spend a call: append the record and increment in-flight.
    mutating func record(at: Date, skillID: String? = nil) {
        ledger.append(HandoffSpend(at: at, skillID: skillID))
        inFlight += 1
    }

    /// A fire-and-forget launch is "done" → decrement in-flight (v1: immediately after a successful open).
    /// The ledger entry stays (it counts against the daily cap); only the in-flight count drops.
    mutating func reap() {
        inFlight = max(0, inFlight - 1)
    }

    /// A launch that threw didn't spend → remove the matching ledger entry (by `at`) and drop in-flight,
    /// leaving the cap unchanged from before the call.
    mutating func refund(at: Date) {
        if let idx = ledger.lastIndex(where: { $0.at == at }) {
            ledger.remove(at: idx)
        }
        inFlight = max(0, inFlight - 1)
    }
}

/// The injectable persistence seam for the handoff ledger (`ai-claude-handoff`, task 2.3). The ledger
/// persists under Application Support (like `ClipboardStore`/`ParkedSessionStore`) so the cap survives a
/// relaunch within the rolling window. Tests inject an in-memory or temp-dir store. MLX-free Core.
protocol HandoffLedgerStore: Sendable {
    func load() -> [HandoffSpend]
    func save(_ ledger: [HandoffSpend])
}

/// The default no-disk store (tests / a fresh process with nothing persisted). Records are held in
/// memory only.
final class InMemoryHandoffLedgerStore: HandoffLedgerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: [HandoffSpend]

    init(_ ledger: [HandoffSpend] = []) { self.ledger = ledger }

    func load() -> [HandoffSpend] {
        lock.lock(); defer { lock.unlock() }
        return ledger
    }

    func save(_ ledger: [HandoffSpend]) {
        lock.lock(); defer { lock.unlock() }
        self.ledger = ledger
    }
}

/// The durable JSON ledger store under Application Support (mirroring `DiskAuditLog`'s shape). A read
/// failure yields an empty ledger (a fresh budget); a write failure is swallowed (the in-memory budget
/// still holds the spend) — auditing/cap honesty is best-effort persistence, never a thrown break into
/// the loop. MLX-free Core; its real IO is exercised by the user's build.
final class DiskHandoffLedgerStore: HandoffLedgerStore, @unchecked Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(fileURL: URL = DiskHandoffLedgerStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/ThreeFingerSwitcher/handoff/ledger.json`.
    static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("ThreeFingerSwitcher/handoff", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }

    func load() -> [HandoffSpend] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([HandoffSpend].self, from: data) else { return [] }
        return records
    }

    func save(_ ledger: [HandoffSpend]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(ledger)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: the in-memory budget still holds the spend; a persistence failure does not
            // break the loop (never thrown into the caller).
        }
    }
}
