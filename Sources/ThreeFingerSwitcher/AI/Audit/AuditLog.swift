import Foundation
import os

private let auditLog = Logger(subsystem: "ThreeFingerSwitcher", category: "AuditLog")

/// The append-only audit log seam (`ai-background-autonomy`, design Decision 5). `record(_:)` is
/// NON-BLOCKING and infallible from the caller's view — auditing must never break the agent (design
/// rejected-alternative 6). Viewers (the notch rail drop-down + the Hub AI page) read `recent(limit:)`
/// synchronously. MLX-free Core.
public protocol AuditLog: Sendable {
    /// Append one record (never throws — a persistence failure is observed on the viewer, not here).
    func record(_ r: AuditRecord)
    /// The most-recent records, reverse-chronological, capped at `limit`.
    func recent(limit: Int) -> [AuditRecord]
}

/// A bounded in-memory ring (`ai-background-autonomy`). The synchronous read seam every viewer hits; the
/// disk store wraps this for the durable path. Cap-trims the oldest on overflow.
public final class InMemoryAuditLog: AuditLog, @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [AuditRecord] = []
    /// Retain the most-recent N records.
    public let cap: Int

    public init(cap: Int = 500) {
        self.cap = max(1, cap)
    }

    public func record(_ r: AuditRecord) {
        lock.lock(); defer { lock.unlock() }
        ring.append(r)
        if ring.count > cap { ring.removeFirst(ring.count - cap) }
    }

    public func recent(limit: Int) -> [AuditRecord] {
        lock.lock(); defer { lock.unlock() }
        guard limit > 0 else { return [] }
        return Array(ring.suffix(limit).reversed())
    }

    /// Seed the ring from a persisted slice (newest-last order, as stored). Used by `DiskAuditLog` at init.
    func seed(_ records: [AuditRecord]) {
        lock.lock(); defer { lock.unlock() }
        ring = records.suffix(cap)
    }

    /// The current ring in stored (oldest-first) order — the durable store's write source.
    func snapshot() -> [AuditRecord] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }
}

/// The durable, append-only audit log (`ai-background-autonomy`, design Decision 5). A JSON-lines file
/// under Application Support (mirroring `ParkedSessionStore`/`ClipboardStore`), capped + trimmed on write.
/// `record(_:)` appends to the in-memory ring synchronously (so viewers read it immediately) and bridges
/// the disk write OFF-MAIN on a serialized queue — it NEVER throws into the caller. A persistence failure
/// maps to `AuditError` at the IO boundary and is published on `lastPersistError` for a bounded,
/// non-blocking banner on the Hub viewer (the in-memory ring still has the record).
public final class DiskAuditLog: AuditLog, @unchecked Sendable {
    private let fileURL: URL
    private let ring: InMemoryAuditLog
    private let writeQueue = DispatchQueue(label: "ThreeFingerSwitcher.AuditLog.writer")
    private let lock = NSLock()
    private var _lastPersistError: AuditError?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    public let cap: Int

    public init(fileURL: URL = DiskAuditLog.defaultFileURL(), cap: Int = 500) {
        self.fileURL = fileURL
        self.cap = max(1, cap)
        self.ring = InMemoryAuditLog(cap: self.cap)
        loadIntoRing()
    }

    /// `~/Library/Application Support/ThreeFingerSwitcher/audit/audit.jsonl`.
    public static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("ThreeFingerSwitcher/audit", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    /// The last persistence failure, if any — surfaced bounded + non-blocking on the Hub viewer. `nil`
    /// once a subsequent write succeeds. Internal because `AuditError` is internal (like `ParkError`); the
    /// app-target viewer reaches it within the Core module.
    var lastPersistError: AuditError? {
        lock.lock(); defer { lock.unlock() }
        return _lastPersistError
    }

    public func record(_ r: AuditRecord) {
        ring.record(r)                                   // synchronous: viewers see it immediately
        let snapshot = ring.snapshot()
        writeQueue.async { [weak self] in
            self?.persist(snapshot)                       // off-main; never throws to the caller
        }
    }

    public func recent(limit: Int) -> [AuditRecord] {
        ring.recent(limit: limit)
    }

    // MARK: - IO boundary (maps every throw to AuditError; logged raw)

    /// Read the JSON-lines file into the ring at init. A single corrupt line is skipped (logged); the
    /// rest load — a relaunch never fails wholesale because one line went bad.
    private func loadIntoRing() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        var records: [AuditRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let rec = try? decoder.decode(AuditRecord.self, from: lineData) else {
                auditLog.error("skipping unreadable audit line")
                continue
            }
            records.append(rec)
        }
        ring.seed(records)
    }

    /// Rewrite the (capped) ring as JSON-lines, atomically. Trim-on-write is implicit (the ring is
    /// already capped). Maps every throw to `AuditError` at the boundary; records it for the viewer
    /// banner; NEVER rethrows to the caller.
    private func persist(_ records: [AuditRecord]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            auditLog.error("audit store dir create failed: \(String(describing: error), privacy: .public)")
            setError(.storeUnavailable(detail: String(describing: error)))
            return
        }
        do {
            var lines = ""
            for rec in records.suffix(cap) {
                let data = try encoder.encode(rec)
                if let s = String(data: data, encoding: .utf8) { lines += s + "\n" }
            }
            try lines.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            setError(nil)
        } catch {
            auditLog.error("audit persist failed: \(String(describing: error), privacy: .public)")
            setError(.persistFailed(detail: String(describing: error)))
        }
    }

    private func setError(_ e: AuditError?) {
        lock.lock(); _lastPersistError = e; lock.unlock()
    }
}

/// A test/no-disk double whose write path can be forced to "fail" — the failure surfaces on
/// `lastPersistError` (mirroring `DiskAuditLog`) WITHOUT ever throwing into the caller, so a test can pin
/// "failure is observable, never silent, never thrown into the loop."
public final class FailableInMemoryAuditLog: AuditLog, @unchecked Sendable {
    private let ring: InMemoryAuditLog
    private let lock = NSLock()
    private var _lastPersistError: AuditError?
    /// When true, every `record` marks a persist failure (but still keeps the in-memory record).
    public var failPersist = false

    public init(cap: Int = 500) { self.ring = InMemoryAuditLog(cap: cap) }

    public func record(_ r: AuditRecord) {
        ring.record(r)                                   // never lost
        lock.lock()
        _lastPersistError = failPersist ? .persistFailed(detail: "forced") : nil
        lock.unlock()
    }

    public func recent(limit: Int) -> [AuditRecord] { ring.recent(limit: limit) }

    var lastPersistError: AuditError? {
        lock.lock(); defer { lock.unlock() }
        return _lastPersistError
    }
}
