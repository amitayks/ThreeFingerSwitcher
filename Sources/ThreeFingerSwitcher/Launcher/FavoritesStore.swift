import Foundation
import Combine

/// Persists the launcher's `Favorites` as a single versioned JSON blob in `UserDefaults`.
///
/// This departs from `AppSettings`' scalar-per-key style because the data is a rich nested list;
/// `schemaVersion` enables forward migration. Like `AppSettings`, the initializer takes an
/// injectable `UserDefaults` so tests run against an isolated suite. Mutations go through
/// `mutate` so every change is persisted immediately and `@Published` notifies the editor/overlay.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    private let defaults: UserDefaults
    private let key = "favorites"

    @Published private(set) var favorites: Favorites

    private convenience init() { self.init(defaults: .standard) }

    /// Test/seam initializer: inject an isolated `UserDefaults`. Loads the stored record (migrating
    /// older schema versions forward) or seeds the starter bands on first run.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.favorites = Self.load(from: defaults, key: key) ?? Self.seeded()
    }

    // MARK: - Mutation

    /// Apply an edit and persist it. All editor/quick-add paths funnel through here.
    func mutate(_ block: (inout Favorites) -> Void) {
        var copy = favorites
        block(&copy)
        favorites = copy
        save()
    }

    /// Append an item to a band (used by the editor and the menu-bar quick-add).
    func addItem(_ item: LaunchItem, toBand bandID: UUID) {
        mutate { fav in
            guard let i = fav.bands.firstIndex(where: { $0.id == bandID }) else { return }
            fav.bands[i].items.append(item)
        }
    }

    // MARK: - Editor mutations (each persists immediately via `mutate`)

    /// Create a band and return its id (so the editor can select it as the active add target).
    @discardableResult
    func addBand(name: String = "New band",
                 color: ItemColor = ItemColor(red: 0.55, green: 0.55, blue: 0.58)) -> UUID {
        let band = ContextBand(name: name, color: color)
        mutate { $0.bands.append(band) }
        return band.id
    }

    func removeBand(_ id: UUID) {
        mutate { fav in
            fav.bands.removeAll { $0.id == id }
            if fav.homeBandID == id { fav.homeBandID = fav.bands.first?.id }
        }
    }

    func moveBands(fromOffsets: IndexSet, toOffset: Int) {
        mutate { $0.bands.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    /// Edit a band in place by id (name / color / default strategy).
    func updateBand(_ id: UUID, _ block: (inout ContextBand) -> Void) {
        mutate { fav in
            guard let i = fav.bands.firstIndex(where: { $0.id == id }) else { return }
            block(&fav.bands[i])
        }
    }

    func moveItems(inBand bandID: UUID, fromOffsets: IndexSet, toOffset: Int) {
        updateBand(bandID) { $0.items.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    func removeItems(inBand bandID: UUID, at offsets: IndexSet) {
        updateBand(bandID) { $0.items.remove(atOffsets: offsets) }
    }

    func removeItem(_ itemID: UUID, fromBand bandID: UUID) {
        updateBand(bandID) { $0.items.removeAll { $0.id == itemID } }
    }

    /// Edit a single item in place (title / tint / per-item app strategy).
    func updateItem(_ itemID: UUID, inBand bandID: UUID, _ block: (inout LaunchItem) -> Void) {
        updateBand(bandID) { band in
            guard let i = band.items.firstIndex(where: { $0.id == itemID }) else { return }
            block(&band.items[i])
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: - Load / migrate

    private static func load(from defaults: UserDefaults, key: String) -> Favorites? {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Favorites.self, from: data) else { return nil }
        return migrate(decoded)
    }

    /// Forward-migrate an older record to the current schema. Identity for v1; future versions add
    /// cases here. Always stamps the current version so a re-save is normalized.
    static func migrate(_ record: Favorites) -> Favorites {
        var record = record
        // (No migrations yet — v1 is current.) Future: `if record.schemaVersion < N { … }`.
        record.schemaVersion = Favorites.currentSchemaVersion
        return record
    }

    // MARK: - Seed

    /// Starter bands shown on first run — named/colored and pre-filled with a few stock apps so the
    /// gesture is demonstrable immediately. The user re-arranges them from the editor; empty bands
    /// are also valid. Home cell points at the first band, column 0.
    static func seeded() -> Favorites {
        func app(_ name: String, _ path: String) -> LaunchItem? {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return LaunchItem(title: name, icon: .appDefault,
                              kind: .app(bundleURL: URL(fileURLWithPath: path), strategy: nil))
        }
        let dev = ContextBand(name: "Dev", color: ItemColor(red: 0.20, green: 0.48, blue: 0.93),
                              defaultAppStrategy: .alwaysNewWindow,
                              items: [app("Terminal", "/System/Applications/Utilities/Terminal.app"),
                                      app("Finder", "/System/Library/CoreServices/Finder.app")].compactMap { $0 })
        let comms = ContextBand(name: "Comms", color: ItemColor(red: 0.25, green: 0.72, blue: 0.40),
                                defaultAppStrategy: .bringExistingHere,
                                items: [app("Mail", "/System/Applications/Mail.app"),
                                        app("Messages", "/System/Applications/Messages.app")].compactMap { $0 })
        let media = ContextBand(name: "Media", color: ItemColor(red: 0.66, green: 0.36, blue: 0.86),
                                defaultAppStrategy: .smart,
                                items: [app("Music", "/System/Applications/Music.app"),
                                        app("Safari", "/Applications/Safari.app")].compactMap { $0 })
        let system = ContextBand(name: "System", color: ItemColor(red: 0.55, green: 0.55, blue: 0.58),
                                 defaultAppStrategy: .smart,
                                 items: [app("System Settings", "/System/Applications/System Settings.app")].compactMap { $0 })
        return Favorites(bands: [dev, comms, media, system], homeBandID: dev.id, homeColumn: 0)
    }
}
