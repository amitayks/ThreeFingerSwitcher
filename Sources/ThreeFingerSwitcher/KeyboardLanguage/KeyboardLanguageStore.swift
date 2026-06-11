import Foundation
import Combine

/// Persists the per-app keyboard-language memory (`KeyboardLanguageRecord`) as a single versioned
/// JSON blob in `UserDefaults`, exactly mirroring `FavoritesStore`.
///
/// The data is a small `[bundleID: InputSourceID]` map rather than a scalar, so — like the launcher
/// favorites and clipboard history — it lives in one JSON value with a `schemaVersion` for forward
/// migration, not in `AppSettings`' scalar-per-key style. The initializer takes an injectable
/// `UserDefaults` so tests run against an isolated suite. Every write goes through `mutate` so it is
/// persisted immediately and `@Published` notifies any observers.
@MainActor
final class KeyboardLanguageStore: ObservableObject {
    static let shared = KeyboardLanguageStore()

    private let defaults: UserDefaults
    private let key = "keyboardLanguageMap"

    @Published private(set) var record: KeyboardLanguageRecord

    /// Shared singleton uses the standard user defaults.
    private convenience init() { self.init(defaults: .standard) }

    /// Test/seam initializer: inject an isolated `UserDefaults`. Loads the stored record (stamping the
    /// `schemaVersion` forward only when upgrading) or seeds an empty map on first run.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(KeyboardLanguageRecord.self, from: data) {
            let storedVersion = decoded.schemaVersion
            self.record = Self.migrate(decoded)   // stamps forward only when upgrading; identity otherwise
            // Persist once only if this load actually upgraded the schema. A downgrade
            // (storedVersion > current) is NOT saved, so a future record is never clobbered.
            if storedVersion < KeyboardLanguageRecord.currentSchemaVersion { save() }
        } else {
            // First run (or unreadable blob): an empty map is the valid default — the feature learns
            // as the user works, so there is nothing to seed.
            self.record = KeyboardLanguageRecord()
        }
    }

    // MARK: - Read-only snapshot

    /// A read-only snapshot of the current bundle-id → input-source map (the pure policy reads this).
    var map: [String: InputSourceID] { record.map }

    /// The remembered input source for `bundleID`, or nil if the app has never been learned.
    func source(forBundleID bundleID: String) -> InputSourceID? { record.map[bundleID] }

    /// One saved per-site entry, for the Hub's "Saved sites" list: the full context `key`
    /// (`com.google.Chrome|keep.google.com`), the parsed `host` and `browserName` for display, and the
    /// remembered input-source `source`.
    struct SiteEntry: Identifiable {
        var id: String { key }
        let key: String
        let host: String
        let browserName: String
        let source: InputSourceID
    }

    /// The saved per-site entries — only the browser host-keyed entries (per-app entries are excluded),
    /// sorted by host then browser, for a stable list. Reflects exactly the sites the user has set a
    /// language on (the engine only writes a site key when the user actively changes its language).
    func siteEntries() -> [SiteEntry] {
        record.map.compactMap { key, source -> SiteEntry? in
            guard ContextKey.isSiteKey(key), let host = ContextKey.host(from: key) else { return nil }
            return SiteEntry(key: key,
                             host: host,
                             browserName: BrowserRegistry.displayName(for: ContextKey.bundleID(from: key)),
                             source: source)
        }
        .sorted { ($0.host, $0.browserName) < ($1.host, $1.browserName) }
    }

    // MARK: - Mutation

    /// Apply an edit and persist it. All write paths funnel through here.
    func mutate(_ block: (inout KeyboardLanguageRecord) -> Void) {
        var copy = record
        block(&copy)
        record = copy
        save()
    }

    /// Remember `source` as `bundleID`'s input source (the only write path — implicit auto-learn).
    func setSource(_ source: InputSourceID, forBundleID bundleID: String) {
        mutate { $0.map[bundleID] = source }
    }

    /// Forget the remembered source for `bundleID` (a context key). Used by the Hub's saved-sites list
    /// (the per-row remove control) and by the engine when a site is changed back to the global default.
    func removeSource(forBundleID bundleID: String) {
        mutate { $0.map.removeValue(forKey: bundleID) }
    }

    @discardableResult
    func save() -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    // MARK: - Load / migrate

    /// Forward-migrate an older record to the current schema **content** (identity today) and stamp the
    /// current version. Only stamps FORWARD when upgrading; never down-stamps a future record (init
    /// won't persist a non-upgrade, so a newer-schema record written by a future build isn't clobbered).
    static func migrate(_ record: KeyboardLanguageRecord) -> KeyboardLanguageRecord {
        var record = record
        if record.schemaVersion < KeyboardLanguageRecord.currentSchemaVersion {
            record.schemaVersion = KeyboardLanguageRecord.currentSchemaVersion
        }
        return record
    }
}
