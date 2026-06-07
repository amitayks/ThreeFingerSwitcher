import Foundation

/// Persists clipboard history on disk under Application Support — **separate** from `FavoritesStore`
/// (which is a small UserDefaults blob). Small payloads (text, color, url, rtf) live inline in a JSON
/// index; large payloads (image bytes, thumbnails) are externalized to blob files referenced by name.
///
/// The de-dup, retention, and recent-window ordering are pure `nonisolated static` functions over
/// `[ClipboardEntry]`, so they unit-test without touching disk; the instance wraps them with load/save.
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    /// Retention bounds. `maxAge == 0` disables the age cap. Defaults are conservative; the app wires
    /// these from `AppSettings` so the user can tune them.
    struct Retention: Equatable {
        var maxCount: Int
        var maxBytes: Int
        var maxAge: TimeInterval
        static let `default` = Retention(maxCount: 200, maxBytes: 256 * 1024 * 1024, maxAge: 0)
    }

    static let currentSchemaVersion = 1
    /// Inline payloads larger than this are externalized to a blob file on save.
    private static let blobThreshold = 16 * 1024

    private let directory: URL
    private var blobsDir: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    var retention: Retention

    /// The full set of stored entries, newest-influence kept by `capturedAt`. Private — callers use
    /// `recentWindow` / `allEntries`.
    private var entries: [ClipboardEntry] = []

    private convenience init() {
        self.init(directory: Self.defaultDirectory(), retention: .default)
    }

    /// Test/seam initializer: inject an isolated directory (e.g. a temp dir) and retention.
    init(directory: URL, retention: Retention = .default) {
        self.directory = directory
        self.retention = retention
        load()
    }

    /// Default store directory: `~/Library/Application Support/ThreeFingerSwitcher/clipboard`.
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ThreeFingerSwitcher/clipboard", isDirectory: true)
    }

    // MARK: - Reads

    /// Most-recent slice for the launcher band: pinned entries first, then recent non-pinned, capped to
    /// `limit`. Returned entries are **materialized** (blob payloads resolved to inline) so the band /
    /// preview / paste paths never touch disk.
    func recentWindow(limit: Int) -> [ClipboardEntry] {
        Self.recentWindow(entries, limit: limit).map(materialized)
    }

    /// All entries (materialized), newest first — for settings / diagnostics.
    func allEntries() -> [ClipboardEntry] {
        entries.sorted { $0.capturedAt > $1.capturedAt }.map(materialized)
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    // MARK: - Mutations

    /// Record a new copy: de-dup against existing content (a duplicate bumps recency instead of adding
    /// a second entry), then enforce retention caps, then persist.
    func insert(_ entry: ClipboardEntry) {
        entries = Self.dedup(inserting: entry, into: entries)
        entries = Self.evict(entries, retention: retention, now: entry.capturedAt)
        save()
    }

    /// Toggle an entry's pin and persist. Returns the new pin state (nil if the id is unknown). The
    /// live ordering is intentionally NOT changed here — pinned-first ordering is applied on the next
    /// `recentWindow` build, matching the deferred-reorder model.
    @discardableResult
    func togglePin(id: UUID) -> Bool? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[i].pinned.toggle()
        save()
        return entries[i].pinned
    }

    /// Clear history. By default keeps pinned entries; pass `includingPinned: true` to wipe everything.
    func clear(includingPinned: Bool = false) {
        entries = includingPinned ? [] : entries.filter(\.pinned)
        save()
    }

    // MARK: - Pure logic (unit-tested; no disk)

    /// De-dup by fingerprint: if an entry with the same fingerprint exists, refresh its recency and
    /// representations (keeping its id + pin) instead of adding a duplicate; otherwise append.
    nonisolated static func dedup(inserting entry: ClipboardEntry, into entries: [ClipboardEntry]) -> [ClipboardEntry] {
        var out = entries
        if let i = out.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            out[i].capturedAt = entry.capturedAt
            out[i].representations = entry.representations
            out[i].key = entry.key
            out[i].kind = entry.kind
            out[i].sourceApp = entry.sourceApp
            // pin + id preserved
        } else {
            out.append(entry)
        }
        return out
    }

    /// Evict oldest **non-pinned** entries beyond the caps. Pinned entries are exempt from count/age
    /// eviction. Returns the retained set.
    nonisolated static func evict(_ entries: [ClipboardEntry], retention: Retention, now: Date) -> [ClipboardEntry] {
        var pinned = entries.filter(\.pinned)
        var unpinned = entries.filter { !$0.pinned }.sorted { $0.capturedAt > $1.capturedAt }   // newest first

        // Age cap (non-pinned only).
        if retention.maxAge > 0 {
            unpinned = unpinned.filter { now.timeIntervalSince($0.capturedAt) <= retention.maxAge }
        }
        // Count cap (non-pinned only): pinned don't consume the count budget.
        let countBudget = max(0, retention.maxCount - pinned.count)
        if unpinned.count > countBudget {
            unpinned = Array(unpinned.prefix(countBudget))
        }
        // Byte cap (non-pinned only): keep newest until the budget is spent.
        if retention.maxBytes > 0 {
            let pinnedBytes = pinned.reduce(0) { $0 + $1.inlineByteSize }
            var budget = max(0, retention.maxBytes - pinnedBytes)
            var kept: [ClipboardEntry] = []
            for e in unpinned {
                let size = e.inlineByteSize
                if size <= budget { kept.append(e); budget -= size }
            }
            unpinned = kept
        }
        // Stable output: pinned (newest first) then retained non-pinned (newest first).
        pinned.sort { $0.capturedAt > $1.capturedAt }
        return pinned + unpinned
    }

    /// The band slice: pinned (newest first) then recent non-pinned, capped to `limit`.
    nonisolated static func recentWindow(_ entries: [ClipboardEntry], limit: Int) -> [ClipboardEntry] {
        guard limit > 0 else { return [] }
        let pinned = entries.filter(\.pinned).sorted { $0.capturedAt > $1.capturedAt }
        let rest = entries.filter { !$0.pinned }.sorted { $0.capturedAt > $1.capturedAt }
        let remaining = max(0, limit - pinned.count)
        return Array(pinned.prefix(limit)) + Array(rest.prefix(remaining))
    }

    // MARK: - Persistence

    private struct StoredIndex: Codable {
        var schemaVersion: Int
        var entries: [ClipboardEntry]
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(StoredIndex.self, from: data) else { return }
        entries = Self.migrate(decoded).entries
    }

    /// Forward-migrate an older index to the current schema. Identity for v1; future versions branch here.
    private static func migrate(_ index: StoredIndex) -> StoredIndex {
        var index = index
        // (No migrations yet — v1 is current.)
        index.schemaVersion = currentSchemaVersion
        return index
    }

    private func save() {
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        // Externalize large inline payloads to blobs so the index JSON stays small.
        let externalized = entries.map(externalizedForStorage)
        let record = StoredIndex(schemaVersion: Self.currentSchemaVersion, entries: externalized)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: indexURL, options: .atomic)
        // Prune against the names the just-written index references (the in-memory entries are still
        // inline, so they can't be the source of truth for which blobs are live).
        pruneOrphanBlobs(keeping: referencedBlobs(externalized))
    }

    private func referencedBlobs(_ entries: [ClipboardEntry]) -> Set<String> {
        Set(entries.flatMap { entry in
            entry.representations.values.compactMap { payload -> String? in
                if case let .blob(name) = payload { return name }; return nil
            }
        })
    }

    /// Write large inline payloads to blob files and replace them with `.blob` references for storage.
    /// Small payloads stay inline. Deterministic blob names (by content) make re-saves idempotent.
    private func externalizedForStorage(_ entry: ClipboardEntry) -> ClipboardEntry {
        var e = entry
        e.representations = entry.representations.mapValues { payload in
            switch payload {
            case .blob:
                return payload   // already external
            case .inline(let data):
                guard data.count > Self.blobThreshold else { return payload }
                let name = "\(entry.id.uuidString)-\(stableName(for: data)).bin"
                let url = blobsDir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? data.write(to: url, options: .atomic)
                }
                return .blob(name)
            }
        }
        return e
    }

    /// Resolve any `.blob` references back to `.inline` by reading the blob files (best-effort: a
    /// missing blob drops that representation rather than failing the whole entry).
    private func materialized(_ entry: ClipboardEntry) -> ClipboardEntry {
        var e = entry
        e.representations = entry.representations.compactMapValues { payload in
            switch payload {
            case .inline:
                return payload
            case .blob(let name):
                guard let data = try? Data(contentsOf: blobsDir.appendingPathComponent(name)) else { return nil }
                return .inline(data)
            }
        }
        return e
    }

    /// Remove blob files not in the `referenced` set (the live blob names of the written index).
    private func pruneOrphanBlobs(keeping referenced: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func stableName(for data: Data) -> String {
        // Cheap, dependency-free content hash (FNV-1a 64-bit) for a deterministic blob filename.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
