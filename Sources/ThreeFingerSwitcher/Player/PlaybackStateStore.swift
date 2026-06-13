import Foundation

/// The per-file playback state remembered for resume (`media-player` spec: "Per-file resume of playback
/// state"): where you were, which tracks, what volume/rate, and when you last opened it.
///
/// Keyed by the file's stable identity (absolute path) with a **size + modification-date tiebreak** stored
/// alongside, so a *different* file later at the same path (or a moved/edited file) doesn't resume to a
/// stale position — the lookup requires size+mtime to match, else it starts fresh. Full content hashing is
/// deliberately avoided (too costly for multi-GB media); path+size+mtime is cheap and good enough.
struct PlaybackState: Codable, Equatable {
    var resumePosition: TimeInterval
    var duration: TimeInterval
    var audioTrackID: String?
    var subtitleTrackID: String?
    var volume: Double
    var rate: Double
    var lastOpened: Date
    /// Identity tiebreak: the file's size in bytes when state was recorded.
    var fileSize: Int64
    /// Identity tiebreak: the file's modification date when state was recorded (nil if unavailable).
    var modificationDate: Date?
}

/// Persists `PlaybackState` per file on disk under Application Support — a small JSON index, separate from
/// every other store (the `ClipboardStore` shape: pure `nonisolated static` retention/resume helpers that
/// unit-test without touching disk, wrapped by an instance that loads/saves). The map is keyed by absolute
/// path; the bounded LRU-by-`lastOpened` cap keeps it from growing without limit.
@MainActor
final class PlaybackStateStore {
    static let shared = PlaybackStateStore()

    /// Maximum remembered files; beyond this the least-recently-opened entries are evicted.
    /// `nonisolated` so it can seed the `init` default argument (a nonisolated context).
    nonisolated private static let defaultCap = 500

    private let directory: URL
    private let cap: Int
    private var indexURL: URL { directory.appendingPathComponent("playback-index.json", isDirectory: false) }

    /// path → state. Private; callers use `state(forPath:…)` / `record(…)`.
    private var states: [String: PlaybackState] = [:]

    private convenience init() {
        self.init(directory: Self.defaultDirectory(), cap: Self.defaultCap)
    }

    /// Test/seam initializer: inject an isolated directory (e.g. a temp dir) and cap.
    init(directory: URL, cap: Int = PlaybackStateStore.defaultCap) {
        self.directory = directory
        self.cap = max(1, cap)
        load()
    }

    /// Default store directory: `~/Library/Application Support/ThreeFingerSwitcher/player`.
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ThreeFingerSwitcher/player", isDirectory: true)
    }

    // MARK: - Reads

    /// The saved state for `path` **only if** the stored size+mtime match the current file's (so a moved
    /// or edited file at the same path starts fresh). `nil` when there is no matching state.
    func state(forPath path: String, size: Int64, modificationDate: Date?) -> PlaybackState? {
        guard let saved = states[path] else { return nil }
        guard Self.identityMatches(saved: saved, size: size, modificationDate: modificationDate) else {
            return nil
        }
        return saved
    }

    var count: Int { states.count }

    // MARK: - Mutations

    /// Record (or update) the state for `path` and persist, then enforce the LRU cap.
    func record(path: String, state: PlaybackState) {
        states[path] = state
        states = Self.evict(states, cap: cap)
        save()
    }

    // MARK: - Pure helpers (unit-tested without disk)

    /// Whether a saved entry's identity tiebreak matches the current file. Size must match exactly; the
    /// modification date must match when both are present (a missing date on either side is treated as a
    /// match, since some filesystems don't report one — size alone then guards).
    nonisolated static func identityMatches(saved: PlaybackState, size: Int64,
                                            modificationDate: Date?) -> Bool {
        guard saved.fileSize == size else { return false }
        guard let a = saved.modificationDate, let b = modificationDate else { return true }
        return abs(a.timeIntervalSince(b)) < 1.0   // 1s tolerance for FS timestamp granularity
    }

    /// The position to start at, applying the resume rule: start fresh (0) when the saved position is
    /// before `threshold` (barely started) or within `nearEndMargin` of the end (essentially finished);
    /// otherwise resume from the saved position.
    nonisolated static func resumePosition(savedPosition: TimeInterval, duration: TimeInterval,
                                           threshold: TimeInterval, nearEndMargin: TimeInterval) -> TimeInterval {
        guard savedPosition >= threshold else { return 0 }
        if duration > 0, savedPosition >= duration - nearEndMargin { return 0 }
        return savedPosition
    }

    /// Keep only the `cap` most-recently-opened entries (LRU eviction by `lastOpened`).
    nonisolated static func evict(_ states: [String: PlaybackState], cap: Int) -> [String: PlaybackState] {
        guard states.count > cap else { return states }
        let keep = states.sorted { $0.value.lastOpened > $1.value.lastOpened }.prefix(cap)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: PlaybackState].self, from: data) else {
            return
        }
        states = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(states)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // Persistence is best-effort — a write failure must never crash playback. The in-memory map
            // stays correct for the session; the next successful save catches up.
        }
    }
}
