import Foundation
import DeviceLinkProtocol

/// Persists the iPhone app's moved-items list. Every representation's bytes go to a **blob file**; the
/// JSON index holds only metadata + blob filenames, so the index stays small and the store never holds
/// all payloads in memory (it materializes to `MovedItem` only on `list()`). Newest-first, replace-by-id,
/// with a count cap that evicts the oldest and deletes their blobs. Injectable directory for tests.
public final class MovedItemStore {
    private let directory: URL
    private var blobsDir: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public var maxCount: Int

    private var stored: [StoredItem] = []

    public init(directory: URL, maxCount: Int = 300) {
        self.directory = directory
        self.maxCount = maxCount
        load()
    }

    public var count: Int { stored.count }

    /// Items newest-first, with representation bytes materialized from blobs.
    public func list() -> [MovedItem] {
        stored.sorted { $0.movedAt > $1.movedAt }.compactMap(materialize)
    }

    /// Insert (or replace a same-id record), evicting the oldest beyond the cap.
    public func insert(_ item: MovedItem) {
        removeBlobs(forID: item.id)
        stored.removeAll { $0.id == item.id }
        stored.append(writeBlobs(for: item))
        evict()
        save()
    }

    public func remove(id: UUID) {
        removeBlobs(forID: id)
        stored.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        for item in stored { removeBlobs(forID: item.id) }
        stored.removeAll()
        save()
    }

    // MARK: - On-disk model

    private struct StoredItem: Codable {
        var id: UUID
        var direction: MoveDirection
        var kind: LinkItemKind
        var title: String
        var peerName: String?
        var movedAt: Date
        var repFiles: [String: String] // uti -> blob filename
    }

    // MARK: - Blobs

    private func writeBlobs(for item: MovedItem) -> StoredItem {
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        var repFiles: [String: String] = [:]
        for (uti, data) in item.representations {
            let name = "\(item.id.uuidString)-\(stableName(uti)).bin"
            let url = blobsDir.appendingPathComponent(name)
            try? data.write(to: url, options: .atomic)
            repFiles[uti] = name
        }
        return StoredItem(id: item.id, direction: item.direction, kind: item.kind,
                          title: item.title, peerName: item.peerName, movedAt: item.movedAt, repFiles: repFiles)
    }

    private func materialize(_ s: StoredItem) -> MovedItem? {
        var reps: [String: Data] = [:]
        for (uti, name) in s.repFiles {
            if let data = try? Data(contentsOf: blobsDir.appendingPathComponent(name)) { reps[uti] = data }
        }
        return MovedItem(id: s.id, direction: s.direction, kind: s.kind, title: s.title,
                         peerName: s.peerName, movedAt: s.movedAt, representations: reps)
    }

    private func removeBlobs(forID id: UUID) {
        guard let item = stored.first(where: { $0.id == id }) else { return }
        for name in item.repFiles.values {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
        }
    }

    private func evict() {
        guard stored.count > maxCount else { return }
        let sorted = stored.sorted { $0.movedAt > $1.movedAt }
        let keep = Array(sorted.prefix(maxCount))
        let drop = sorted.dropFirst(maxCount)
        for item in drop {
            for name in item.repFiles.values {
                try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(name))
            }
        }
        stored = keep
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([StoredItem].self, from: data) else { return }
        stored = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func stableName(_ uti: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in uti.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
