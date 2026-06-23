import Foundation
import os

private let parkStoreLog = Logger(subsystem: "ThreeFingerSwitcher", category: "ParkedSessionStore")

/// The durable parked-conversation store (design §3). This slice OWNS persistence; it consumes
/// `AgentConversation` (`ai-conversation-runtime`) verbatim — no duplicate type, no second retriever.
/// A small synchronous read seam over an in-memory index, with disk IO bridged off the read path the way
/// the Files band bridges its async lister: the scheduler/rail read `all()`/`conversation(_:)`
/// synchronously, while `upsert`/`remove` persist behind the boundary. Every `FileManager`/JSON-coding
/// throw maps into `ParkError` AT THE IO BOUNDARY (raw text to the log only). MLX-free Core.
protocol ParkedSessionStore: AnyObject, Sendable {
    /// The lightweight rail/scheduler rows (sorted oldest-updated first).
    func all() -> [ParkedSession]
    /// The full durable conversation for a session, if persisted.
    func conversation(_ id: AgentSessionID) -> AgentConversation?
    /// Persist (insert/replace) a session's row + conversation.
    func upsert(_ session: ParkedSession, conversation: AgentConversation) throws
    /// Update just the lightweight row (state/badge/nextRunAt) without rewriting the transcript.
    func upsertRow(_ session: ParkedSession) throws
    /// Remove a session's row + conversation (discard / eviction).
    func remove(_ id: AgentSessionID) throws
    /// The persisted one-line resume for a (possibly slept) session.
    func oneLineResume(_ id: AgentSessionID) -> String?
    /// Persist a one-line resume for a session being put to sleep (KV dropped elsewhere).
    func persistResume(_ id: AgentSessionID, resume: String) throws
}

/// One persisted record: the lightweight row + the full conversation + an optional one-line resume.
private struct ParkedRecord: Codable {
    var row: ParkedSession
    var conversation: AgentConversation
    var resume: String?
}

/// The disk-backed store. One JSON file per session under `…/ThreeFingerSwitcher/parked`, plus an
/// in-memory index loaded once at init and kept in sync on each write — so reads are synchronous and
/// cheap and the rail rebuilds from disk on relaunch.
final class DiskParkedSessionStore: ParkedSessionStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var index: [AgentSessionID: ParkedRecord] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(directory: URL = DiskParkedSessionStore.defaultDirectory()) {
        self.directory = directory
        loadIndex()
    }

    /// `~/Library/Application Support/ThreeFingerSwitcher/parked` (parallels `MemoryStore`).
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ThreeFingerSwitcher/parked", isDirectory: true)
    }

    private func fileURL(for id: AgentSessionID) -> URL {
        directory.appendingPathComponent(id.raw.uuidString + ".json")
    }

    /// Read every record into the in-memory index. A single corrupt file is skipped (logged), the rest
    /// load — a relaunch never fails wholesale because one session's JSON went bad.
    private func loadIndex() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in entries where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(ParkedRecord.self, from: data) else {
                parkStoreLog.error("skipping unreadable parked record at \(file.lastPathComponent, privacy: .public)")
                continue
            }
            index[record.row.id] = record
        }
    }

    func all() -> [ParkedSession] {
        lock.lock(); defer { lock.unlock() }
        return index.values.map(\.row).sorted { $0.updatedAt < $1.updatedAt }
    }

    func conversation(_ id: AgentSessionID) -> AgentConversation? {
        lock.lock(); defer { lock.unlock() }
        return index[id]?.conversation
    }

    func oneLineResume(_ id: AgentSessionID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return index[id]?.resume ?? index[id]?.conversation.compactedSummary
    }

    func upsert(_ session: ParkedSession, conversation: AgentConversation) throws {
        let existingResume = peekResume(session.id)
        let record = ParkedRecord(row: session, conversation: conversation, resume: existingResume)
        try write(record)
    }

    func upsertRow(_ session: ParkedSession) throws {
        lock.lock()
        guard var record = index[session.id] else {
            lock.unlock()
            // A row-only upsert for a session with no stored conversation persists a placeholder
            // conversation under the same identity (so the rail rebuilds), never a silent drop.
            let placeholder = AgentConversation(id: session.id, title: session.title, messages: [])
            try upsert(session, conversation: placeholder)
            return
        }
        record.row = session
        lock.unlock()
        try write(record)
    }

    func remove(_ id: AgentSessionID) throws {
        lock.lock(); index[id] = nil; lock.unlock()
        do {
            let url = fileURL(for: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            parkStoreLog.error("parked remove failed: \(String(describing: error), privacy: .public)")
            throw ParkError.persistFailed(detail: String(describing: error))
        }
    }

    func persistResume(_ id: AgentSessionID, resume: String) throws {
        lock.lock()
        guard var record = index[id] else {
            lock.unlock()
            throw ParkError.resumeMissing
        }
        record.resume = resume
        lock.unlock()
        try write(record)
    }

    private func peekResume(_ id: AgentSessionID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return index[id]?.resume
    }

    /// The IO boundary: create the dir + atomically write the record, mapping every throw to `ParkError`.
    private func write(_ record: ParkedRecord) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            parkStoreLog.error("parked store dir create failed: \(String(describing: error), privacy: .public)")
            throw ParkError.storeUnavailable(detail: String(describing: error))
        }
        do {
            let data = try encoder.encode(record)
            try data.write(to: fileURL(for: record.row.id), options: .atomic)
        } catch {
            parkStoreLog.error("parked persist failed: \(String(describing: error), privacy: .public)")
            throw ParkError.persistFailed(detail: String(describing: error))
        }
        lock.lock(); index[record.row.id] = record; lock.unlock()
    }
}

/// An in-memory store for tests + the no-disk path. Same contract, no IO — a `failingStore` flag forces
/// the `ParkError` mapping path so tests can pin the "failure is observable, never silent" invariant.
final class InMemoryParkedSessionStore: ParkedSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var index: [AgentSessionID: ParkedRecord] = [:]
    /// When true, every write throws `.persistFailed` (simulating a forced IO failure at the boundary).
    var failWrites = false

    init() {}

    func all() -> [ParkedSession] {
        lock.lock(); defer { lock.unlock() }
        return index.values.map(\.row).sorted { $0.updatedAt < $1.updatedAt }
    }

    func conversation(_ id: AgentSessionID) -> AgentConversation? {
        lock.lock(); defer { lock.unlock() }
        return index[id]?.conversation
    }

    func oneLineResume(_ id: AgentSessionID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return index[id]?.resume ?? index[id]?.conversation.compactedSummary
    }

    func upsert(_ session: ParkedSession, conversation: AgentConversation) throws {
        if failWrites { throw ParkError.persistFailed(detail: "forced") }
        lock.lock(); defer { lock.unlock() }
        let resume = index[session.id]?.resume
        index[session.id] = ParkedRecord(row: session, conversation: conversation, resume: resume)
    }

    func upsertRow(_ session: ParkedSession) throws {
        if failWrites { throw ParkError.persistFailed(detail: "forced") }
        lock.lock()
        if var record = index[session.id] {
            record.row = session
            index[session.id] = record
            lock.unlock()
        } else {
            lock.unlock()
            try upsert(session, conversation: AgentConversation(id: session.id, title: session.title, messages: []))
        }
    }

    func remove(_ id: AgentSessionID) throws {
        lock.lock(); defer { lock.unlock() }
        index[id] = nil
    }

    func persistResume(_ id: AgentSessionID, resume: String) throws {
        if failWrites { throw ParkError.persistFailed(detail: "forced") }
        lock.lock(); defer { lock.unlock() }
        guard var record = index[id] else { throw ParkError.resumeMissing }
        record.resume = resume
        index[id] = record
    }
}
