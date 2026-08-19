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
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Favorites.self, from: data) {
            let storedVersion = decoded.schemaVersion
            self.favorites = Self.migrate(decoded)   // stamps forward only when upgrading; identity otherwise
            // Persist once if the load did one-time upgrade work. A downgrade (storedVersion > current)
            // is NOT saved, so a future record is never clobbered.
            if storedVersion < Favorites.currentSchemaVersion { save() }
        } else {
            self.favorites = Self.seeded()
            // Persist the seed so its ids are stable across relaunch.
            save()
        }
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

    /// Create a band and return its id (so the editor can select it as the active add target). Bands are
    /// identified by their **icon** (the launcher shows icons, not names), so a new band starts with a
    /// neutral default icon and no name — the user picks an icon, not a title.
    @discardableResult
    func addBand(name: String = "",
                 icon: ItemIcon = .sfSymbol("square.grid.2x2.fill"),
                 color: ItemColor = ItemColor(red: 0.55, green: 0.55, blue: 0.58)) -> UUID {
        let band = ContextBand(name: name, color: color, icon: icon)
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

    /// Move an item to a different band, appending it to the destination. No-op when the item/bands
    /// can't be resolved or source == destination.
    func moveItem(_ itemID: UUID, fromBand: UUID, toBand: UUID) {
        guard fromBand != toBand else { return }
        mutate { fav in
            guard let si = fav.bands.firstIndex(where: { $0.id == fromBand }),
                  let ii = fav.bands[si].items.firstIndex(where: { $0.id == itemID }),
                  let di = fav.bands.firstIndex(where: { $0.id == toBand }) else { return }
            let item = fav.bands[si].items.remove(at: ii)
            fav.bands[di].items.append(item)
        }
    }

    /// Edit a single item in place (title / tint / per-item app strategy).
    func updateItem(_ itemID: UUID, inBand bandID: UUID, _ block: (inout LaunchItem) -> Void) {
        updateBand(bandID) { band in
            guard let i = band.items.firstIndex(where: { $0.id == itemID }) else { return }
            block(&band.items[i])
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let data = try? JSONEncoder().encode(favorites) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    // MARK: - Load / migrate

    /// The retired "AI" band's sentinel id (the former `AIBand.bandID`). Kept only so the v3
    /// migration can recognize and remove the seeded band; users' own bands are never touched.
    private static let legacyAIBandID = UUID(uuidString: "A1C0AAAA-0000-4000-8000-000000000001")!

    /// Forward-migrate an older record to the current schema content and stamp the current version.
    /// v3 (the local-AI + Files-band removal): retired item kinds were already dropped per-item by
    /// the lossy band decode (`ContextBand.FailableItem`); here the seeded "AI" band is removed once
    /// it holds nothing else (a renamed/repurposed band with surviving items is the user's — kept).
    static func migrate(_ record: Favorites) -> Favorites {
        var record = record
        if record.schemaVersion < 3 {
            record.bands.removeAll { $0.id == legacyAIBandID && $0.items.isEmpty }
            if let home = record.homeBandID, !record.bands.contains(where: { $0.id == home }) {
                record.homeBandID = record.bands.first?.id
            }
        }
        // Only stamp FORWARD when upgrading; never down-stamp a future record. (init won't persist a
        // non-upgrade, so a newer-schema record written by a future build isn't clobbered on launch.)
        if record.schemaVersion < Favorites.currentSchemaVersion {
            record.schemaVersion = Favorites.currentSchemaVersion
        }
        return record
    }

    // MARK: - Seed

    /// Starter bands shown on first run — the SAME composition the First Touch wizard's tour
    /// teaches with, so what the user learns in onboarding is exactly what the launcher holds:
    /// **Apps** (flame — the stock apps in one row) and **Windows** (display — the twelve
    /// window-management actions, two exact grid rows; built by `WizardTourBands.windowsBand()`
    /// so tour and seed cannot drift). The user re-arranges everything from the editor; empty
    /// bands are also valid. Home cell points at the Apps band, column 0.
    static func seeded() -> Favorites {
        func app(_ name: String, _ path: String) -> LaunchItem? {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return LaunchItem(title: name, icon: .appDefault,
                              kind: .app(bundleURL: URL(fileURLWithPath: path), strategy: nil))
        }
        let apps = ContextBand(name: "Apps", color: ItemColor(red: 0.95, green: 0.45, blue: 0.20),
                               icon: .sfSymbol("flame.fill"),
                               defaultAppStrategy: .smart,
                               items: [app("Safari", "/Applications/Safari.app"),
                                       app("Mail", "/System/Applications/Mail.app"),
                                       app("Messages", "/System/Applications/Messages.app"),
                                       app("Music", "/System/Applications/Music.app"),
                                       app("Terminal", "/System/Applications/Utilities/Terminal.app"),
                                       app("Finder", "/System/Library/CoreServices/Finder.app"),
                                       app("System Settings", "/System/Applications/System Settings.app")].compactMap { $0 })
        let windows = WizardTourBands.windowsBand()
        return Favorites(bands: [apps, windows], homeBandID: apps.id, homeColumn: 0)
    }
}
