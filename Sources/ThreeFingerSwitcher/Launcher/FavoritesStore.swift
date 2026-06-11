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
    /// older schema versions forward, and folding any legacy AI commands into a normal "AI" band on the
    /// first upgrade) or seeds the starter bands (including the "AI" band) on first run.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Favorites.self, from: data) {
            let storedVersion = decoded.schemaVersion
            var record = Self.migrate(decoded)   // stamps forward only when upgrading; identity otherwise
            let didFold = Self.foldInLegacyAICommands(into: &record, storedVersion: storedVersion, defaults: defaults)
            self.favorites = record
            // Persist once if the load did one-time work (an upgrade and/or the AI fold-in). The legacy
            // "aiCommands" key is retired ONLY after the new record is durably written — a failed save
            // leaves it intact so the fold-in retries next launch (never lose data; spec/design D4).
            // A downgrade (storedVersion > current) is NOT saved, so a future record is never clobbered.
            if didFold || storedVersion < Favorites.currentSchemaVersion {
                if save(), storedVersion < Favorites.aiCommandsFoldedSchemaVersion {
                    defaults.removeObject(forKey: Self.legacyAICommandsKey)
                }
            }
        } else {
            self.favorites = Self.seeded()
            // Persist the seed so its ids (notably the seeded AI commands') are stable across relaunch.
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

    /// Move an item to a different band (any kind, including `.aiCommand`), appending it to the
    /// destination. No-op when the item/bands can't be resolved or source == destination.
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

    /// Forward-migrate an older record to the current schema **content** (identity today) and stamp the
    /// current version. The AI fold-in is handled separately (`foldInLegacyAICommands`) because it needs
    /// `UserDefaults` access to read+retire the legacy `aiCommands` key.
    static func migrate(_ record: Favorites) -> Favorites {
        var record = record
        // Only stamp FORWARD when upgrading; never down-stamp a future record. (init won't persist a
        // non-upgrade, so a newer-schema record written by a future build isn't clobbered on launch.)
        if record.schemaVersion < Favorites.currentSchemaVersion {
            record.schemaVersion = Favorites.currentSchemaVersion
        }
        return record
    }

    // MARK: - AI fold-in migration (one-time, idempotent)

    /// The legacy key the former `AICommandStore` persisted its commands under.
    private static let legacyAICommandsKey = "aiCommands"

    /// One-time AI fold-in (configuration-hub): when upgrading from a record predating the fold-in
    /// (`storedVersion < aiCommandsFoldedSchemaVersion`), append an "AI" band to `record`. It does NOT
    /// touch the legacy key — the caller retires `aiCommands` only after a successful save, so a failed
    /// write never loses commands. Idempotent: never appends a second "AI" band. Cases:
    /// • legacy `aiCommands` present with commands → import them, preserving id + order;
    /// • legacy key present but empty → opted in then cleared: import nothing (respect the empty choice);
    /// • legacy key ABSENT → never opted in → seed the default "AI" band for discoverability (design D4).
    /// Returns whether it changed `record`.
    @discardableResult
    static func foldInLegacyAICommands(into record: inout Favorites, storedVersion: Int,
                                       defaults: UserDefaults) -> Bool {
        guard storedVersion < Favorites.aiCommandsFoldedSchemaVersion else { return false }
        guard !record.bands.contains(where: { AIBand.isAIBand($0) }) else { return false }
        if let data = defaults.data(forKey: legacyAICommandsKey) {
            // Opted in before: import their commands (an empty record imports nothing).
            guard let commands = decodeLegacyAICommands(data), !commands.isEmpty else { return false }
            record.bands.append(AIBand.band(from: commands))
            return true
        }
        // Never opted in (no legacy key): seed the default "AI" band so the feature is discoverable.
        record.bands.append(AIBand.seededBand())
        return true
    }

    /// Decode the legacy `AICommandStore` on-disk record (`{ schemaVersion, commands }`).
    private static func decodeLegacyAICommands(_ data: Data) -> [AICommand]? {
        struct LegacyStored: Codable { var schemaVersion: Int; var commands: [AICommand] }
        return (try? JSONDecoder().decode(LegacyStored.self, from: data))?.commands
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
                              icon: .sfSymbol("chevron.left.forwardslash.chevron.right"),
                              defaultAppStrategy: .alwaysNewWindow,
                              items: [app("Terminal", "/System/Applications/Utilities/Terminal.app"),
                                      app("Finder", "/System/Library/CoreServices/Finder.app")].compactMap { $0 })
        let comms = ContextBand(name: "Comms", color: ItemColor(red: 0.25, green: 0.72, blue: 0.40),
                                icon: .sfSymbol("message.fill"),
                                defaultAppStrategy: .bringExistingHere,
                                items: [app("Mail", "/System/Applications/Mail.app"),
                                        app("Messages", "/System/Applications/Messages.app")].compactMap { $0 })
        let media = ContextBand(name: "Media", color: ItemColor(red: 0.66, green: 0.36, blue: 0.86),
                                icon: .sfSymbol("play.circle.fill"),
                                defaultAppStrategy: .smart,
                                items: [app("Music", "/System/Applications/Music.app"),
                                        app("Safari", "/Applications/Safari.app")].compactMap { $0 })
        let system = ContextBand(name: "System", color: ItemColor(red: 0.55, green: 0.55, blue: 0.58),
                                 icon: .sfSymbol("gearshape.fill"),
                                 defaultAppStrategy: .smart,
                                 items: [app("System Settings", "/System/Applications/System Settings.app")].compactMap { $0 })
        // Fresh installs also get the "AI" band (a normal, editable band of seeded AI commands). Its
        // items only act once AI is enabled; firing one while AI is off opens the enable/download canvas.
        return Favorites(bands: [dev, comms, media, system, AIBand.seededBand()],
                         homeBandID: dev.id, homeColumn: 0)
    }
}
