import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the launcher data model (`LaunchItem`) and its persistence (`FavoritesStore`):
/// Codable round-trips across every kind, versioned persistence, deterministic home-cell
/// resolution, and the absence of any recency reordering on access.
@MainActor
final class LaunchItemTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.Favorites.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    // MARK: - Codable round-trips

    /// Build a favorites tree exercising every item kind, including a preset that references others.
    private func sampleFavorites() -> Favorites {
        let term = LaunchItem(title: "Terminal", icon: .appDefault,
                              kind: .app(bundleURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                         strategy: .alwaysNewWindow))
        let proj = LaunchItem(title: "Projects", icon: .fileIcon,
                              kind: .path(URL(fileURLWithPath: "/Users/me/projects")))
        let site = LaunchItem(title: "Docs", icon: .sfSymbol("book"),
                              tint: ItemColor(red: 1, green: 0, blue: 0),
                              kind: .url(URL(string: "https://example.com")!))
        let short = LaunchItem(title: "Focus", icon: .emoji("🎯"), kind: .shortcut(name: "Focus Mode"))
        let shell = LaunchItem(title: "Backup", icon: .sfSymbol("externaldrive"),
                               kind: .script(.shell("echo hi")))
        let work = LaunchItem(title: "Work", icon: .emoji("🧑‍💻"),
                              kind: .preset(itemIDs: [term.id, proj.id, shell.id]))
        let dev = ContextBand(name: "Dev", color: ItemColor(red: 0.2, green: 0.4, blue: 0.9),
                              defaultAppStrategy: .alwaysNewWindow, items: [term, proj, shell, work])
        let web = ContextBand(name: "Web", color: ItemColor(red: 0.6, green: 0.3, blue: 0.8),
                              items: [site, short])
        return Favorites(bands: [dev, web], homeBandID: dev.id, homeColumn: 1)
    }

    func testFavoritesCodableRoundTripPreservesEverything() throws {
        let original = sampleFavorites()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Favorites.self, from: data)
        XCTAssertEqual(decoded, original, "every kind, color, icon, order, and preset reference round-trips")
    }

    func testEachKindEncodesAndDecodes() throws {
        let kinds: [LaunchItemKind] = [
            .app(bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"), strategy: nil),
            .app(bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"), strategy: .bringExistingHere),
            .path(URL(fileURLWithPath: "/tmp")),
            .url(URL(string: "https://a.b")!),
            .shortcut(name: "X"),
            .script(.shell("ls")),
            .script(.appleScript("beep")),
            .script(.file(URL(fileURLWithPath: "/tmp/x.sh"))),
            .action(.closeFrontWindow),
            .preset(itemIDs: [UUID(), UUID()])
        ]
        for kind in kinds {
            let item = LaunchItem(title: "t", icon: .appDefault, kind: kind)
            let data = try JSONEncoder().encode(item)
            let back = try JSONDecoder().decode(LaunchItem.self, from: data)
            XCTAssertEqual(back, item)
        }
    }

    /// A link's new "open with" handler and "new window" flag survive Codable.
    func testURLItemWithHandlerAndWindowRoundTrips() throws {
        let handler = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let item = LaunchItem(title: "Docs", icon: .sfSymbol("link"),
                              kind: .url(URL(string: "https://example.com")!, handler: handler, newWindow: true))
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(LaunchItem.self, from: data)
        XCTAssertEqual(back, item, "a link's open-with handler and new-window flag survive Codable")
    }

    /// Back-compat: a pre-feature `.url` record (no `handler` / `newWindow` keys) still decodes, with both
    /// new fields defaulting to nil — so existing saved bands keep working. Mirrors `.action`'s later
    /// optional values. The legacy shape is produced by stripping the new keys from a real encoding (so
    /// the test doesn't hard-code the synthesized key names).
    func testLegacyURLItemWithoutHandlerOrWindowDecodes() throws {
        let item = LaunchItem(title: "Old", icon: .sfSymbol("link"), kind: .url(URL(string: "https://old.example")!))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        var kind = try XCTUnwrap(json["kind"] as? [String: Any])
        var payload = try XCTUnwrap(kind["url"] as? [String: Any])
        payload.removeValue(forKey: "handler")
        payload.removeValue(forKey: "newWindow")
        kind["url"] = payload
        json["kind"] = kind
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(LaunchItem.self, from: stripped)
        guard case let .url(url, handler, newWindow) = decoded.kind else { return XCTFail("kind is .url") }
        XCTAssertEqual(url.absoluteString, "https://old.example")
        XCTAssertNil(handler, "a legacy .url decodes with no open-with handler")
        XCTAssertNil(newWindow, "a legacy .url decodes with no new-window flag")
    }

    /// The synthetic `.aiCommand` kind round-trips through Codable (it shares the launcher plumbing),
    /// even though it is never written into the persisted Favorites record (it's built fresh on open).
    func testAICommandKindEncodesAndDecodes() throws {
        let command = AICommand(name: "Fix Grammar", icon: .sfSymbol("text.badge.checkmark"),
                                tint: ItemColor(red: 0.25, green: 0.72, blue: 0.40),
                                input: .selection,
                                promptTemplate: "Fix: {input}",
                                output: .runTask(.addToCalendar),
                                model: .onDevice(modelID: "gemma-4-31b"),
                                confirmBeforeRun: true)
        let item = LaunchItem(id: command.id, title: command.name, icon: command.icon,
                              tint: command.tint, kind: .aiCommand(command))
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(LaunchItem.self, from: data)
        XCTAssertEqual(back, item, "the .aiCommand kind and its AICommand payload round-trip")
        guard case let .aiCommand(decoded) = back.kind else { return XCTFail("kind is .aiCommand") }
        XCTAssertEqual(decoded, command, "the carried AICommand survives the round-trip intact")
        XCTAssertFalse(item.isConsequential, "an AI command is not a fire-notification kind")
    }

    // MARK: - Persistence (versioned key)

    func testStorePersistsUnderFavoritesKeyAcrossInstances() {
        let store = FavoritesStore(defaults: defaults)
        let bandID = store.favorites.bands[0].id
        let item = LaunchItem(title: "Added", icon: .appDefault,
                              kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/Mail.app"), strategy: nil))
        store.addItem(item, toBand: bandID)

        // Raw key present, and a fresh store on the same suite reads the addition back.
        XCTAssertNotNil(defaults.data(forKey: "favorites"))
        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertTrue(reloaded.favorites.bands[0].items.contains { $0.title == "Added" })
    }

    func testMigrateStampsCurrentSchemaVersion() {
        var old = sampleFavorites()
        old.schemaVersion = 0
        let migrated = FavoritesStore.migrate(old)
        XCTAssertEqual(migrated.schemaVersion, Favorites.currentSchemaVersion)
        XCTAssertEqual(migrated.bands, old.bands, "v1 migration preserves content")
    }

    func testFreshStoreSeedsStarterBands() {
        let store = FavoritesStore(defaults: defaults)
        XCTAssertFalse(store.favorites.bands.isEmpty, "first run seeds starter bands")
        XCTAssertNotNil(store.favorites.homeBand)
    }

    // MARK: - Deterministic home cell

    func testHomeCellResolution() {
        let fav = sampleFavorites()              // homeBandID = Dev, homeColumn = 1
        XCTAssertEqual(fav.homeBand?.name, "Dev")
        XCTAssertEqual(fav.homeBandIndex, 0)
        XCTAssertEqual(fav.resolvedHomeColumn, 1)
    }

    func testHomeColumnClampsToBandRange() {
        var fav = sampleFavorites()
        fav.homeColumn = 99                       // out of range
        XCTAssertEqual(fav.resolvedHomeColumn, fav.homeBand!.items.count - 1, "clamped to last item")
    }

    func testHomeBandFallsBackToFirstWhenIDMissing() {
        var fav = sampleFavorites()
        fav.homeBandID = UUID()                    // no such band
        XCTAssertEqual(fav.homeBand?.name, "Dev", "falls back to the first band")
        XCTAssertEqual(fav.homeBandIndex, 0)
    }

    // MARK: - No recency reordering

    func testAccessorsReturnStoredOrderUnchanged() {
        let fav = sampleFavorites()
        let titlesBefore = fav.bands.map { $0.items.map(\.title) }
        // Resolving the home cell / looking items up must not mutate or reorder anything.
        _ = fav.resolvedHomeColumn
        _ = fav.item(withID: fav.bands[0].items[0].id)
        let titlesAfter = fav.bands.map { $0.items.map(\.title) }
        XCTAssertEqual(titlesBefore, titlesAfter, "order is fixed; access never reorders")
    }

    func testItemLookupByID() {
        let fav = sampleFavorites()
        let target = fav.bands[1].items[0]
        XCTAssertEqual(fav.item(withID: target.id), target)
        XCTAssertNil(fav.item(withID: UUID()))
    }
}
