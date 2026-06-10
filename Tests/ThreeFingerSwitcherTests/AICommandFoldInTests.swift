import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the configuration-hub AI fold-in: AI commands are now PERSISTED band items inside the
/// `Favorites` record (not a separate `AICommandStore`). Covers: the `Favorites` Codable round-trip
/// with `.aiCommand` items, the fresh-install seed including an editable "AI" band, and the one-time,
/// idempotent migration that imports a legacy `aiCommands` record into a normal "AI" band.
@MainActor
final class AICommandFoldInTests: XCTestCase {

    // MARK: - Helpers

    /// A throwaway, isolated defaults suite (removed at teardown).
    private func makeDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "AICommandFoldInTests.\(label).\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func command(_ name: String, id: UUID = UUID()) -> AICommand {
        AICommand(id: id, name: name, icon: .sfSymbol("sparkles"),
                  tint: ItemColor(red: 0.5, green: 0.4, blue: 0.9),
                  input: .selection, promptTemplate: "{input}", output: .previewOnly)
    }

    /// The legacy on-disk shape the former `AICommandStore` persisted under "aiCommands".
    private struct LegacyStored: Codable { var schemaVersion: Int; var commands: [AICommand] }

    private func writeLegacyCommands(_ commands: [AICommand], to defaults: UserDefaults) {
        let data = try! JSONEncoder().encode(LegacyStored(schemaVersion: 1, commands: commands))
        defaults.set(data, forKey: "aiCommands")
    }

    /// Persist a pre-fold-in (schemaVersion 1) Favorites record under "favorites".
    private func writeV1Favorites(_ bands: [ContextBand], to defaults: UserDefaults) {
        var fav = Favorites(bands: bands, homeBandID: bands.first?.id, homeColumn: 0)
        fav.schemaVersion = 1
        let data = try! JSONEncoder().encode(fav)
        defaults.set(data, forKey: "favorites")
    }

    // MARK: - Codable round-trip with .aiCommand items

    func testFavoritesRoundTripWithAICommandItem() throws {
        let cmd = AICommand(name: "Fix Grammar", icon: .sfSymbol("text.badge.checkmark"),
                            tint: ItemColor(red: 0.2, green: 0.7, blue: 0.4),
                            input: .selection,
                            promptTemplate: "Fix: {input}",
                            output: .runTask(.addToCalendar),
                            confirmBeforeRun: true)
        let item = AIBand.item(for: cmd)
        let band = ContextBand(name: "Work", color: ItemColor(red: 0, green: 0, blue: 1), items: [item])
        let fav = Favorites(bands: [band])

        let data = try JSONEncoder().encode(fav)
        let decoded = try JSONDecoder().decode(Favorites.self, from: data)

        guard case let .aiCommand(roundTripped)? = decoded.bands.first?.items.first?.kind else {
            return XCTFail("the .aiCommand item must survive a Favorites encode/decode")
        }
        XCTAssertEqual(roundTripped, cmd, "the embedded AICommand round-trips intact")
        XCTAssertEqual(decoded.bands.first?.items.first?.id, cmd.id, "item id mirrors the command id")
    }

    // MARK: - Fresh-install seed

    func testFreshSeedIncludesEditableAIBand() {
        let store = FavoritesStore(defaults: makeDefaults())
        guard let ai = store.favorites.bands.first(where: { AIBand.isAIBand($0) }) else {
            return XCTFail("a fresh install seeds an \"AI\" band")
        }
        XCTAssertEqual(ai.name, "AI")
        XCTAssertEqual(ai.items.count, AIBand.seeded().count, "seeded with the starter command set")
        XCTAssertTrue(ai.items.allSatisfy { if case .aiCommand = $0.kind { return true } else { return false } },
                      "every seeded AI item is an .aiCommand")
        // It's a NORMAL band: editable/removable like any other.
        store.removeBand(ai.id)
        XCTAssertFalse(store.favorites.bands.contains { AIBand.isAIBand($0) },
                       "the seeded AI band is a normal band the user can delete")
    }

    func testSchemaVersionIsCurrentAfterSeed() {
        let store = FavoritesStore(defaults: makeDefaults())
        XCTAssertEqual(store.favorites.schemaVersion, Favorites.currentSchemaVersion)
    }

    // MARK: - Migration: legacy commands fold into a normal AI band

    func testMigrationImportsLegacyCommandsPreservingIDsAndOrder() {
        let defaults = makeDefaults()
        let a = command("Alpha"), b = command("Bravo"), c = command("Charlie")
        let dev = ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1))
        writeV1Favorites([dev], to: defaults)
        writeLegacyCommands([a, b, c], to: defaults)

        let store = FavoritesStore(defaults: defaults)

        guard let ai = store.favorites.bands.first(where: { AIBand.isAIBand($0) }) else {
            return XCTFail("migration appends an \"AI\" band")
        }
        XCTAssertEqual(ai.items.map(\.title), ["Alpha", "Bravo", "Charlie"], "order preserved")
        XCTAssertEqual(ai.items.map(\.id), [a.id, b.id, c.id], "command ids preserved")
        // The pre-existing band is untouched and the AI band is appended after it.
        XCTAssertEqual(store.favorites.bands.first?.name, "Dev")
        XCTAssertTrue(AIBand.isAIBand(store.favorites.bands.last!), "AI band appended last")
        XCTAssertEqual(store.favorites.schemaVersion, Favorites.currentSchemaVersion, "version bumped")
        XCTAssertNil(defaults.data(forKey: "aiCommands"), "legacy key retired after a successful fold-in")
    }

    func testMigrationIsIdempotentAcrossReloads() {
        let defaults = makeDefaults()
        writeV1Favorites([ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1))], to: defaults)
        writeLegacyCommands([command("Alpha"), command("Bravo")], to: defaults)

        _ = FavoritesStore(defaults: defaults)            // first launch: folds in
        let reloaded = FavoritesStore(defaults: defaults) // second launch: must NOT duplicate

        let aiBands = reloaded.favorites.bands.filter { AIBand.isAIBand($0) }
        XCTAssertEqual(aiBands.count, 1, "exactly one AI band after a reload (no duplicate)")
        XCTAssertEqual(aiBands.first?.items.count, 2)
    }

    func testMigrationNeverOptedInSeedsDefaultAIBand() {
        // A user who never opted into AI (v1 record, NO aiCommands key) gets the default "AI" band
        // seeded on upgrade, for discoverability (design D4).
        let defaults = makeDefaults()
        writeV1Favorites([ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1))], to: defaults)

        let store = FavoritesStore(defaults: defaults)
        guard let ai = store.favorites.bands.first(where: { AIBand.isAIBand($0) }) else {
            return XCTFail("never-opted-in upgrade seeds the default AI band (design D4)")
        }
        XCTAssertEqual(ai.items.count, AIBand.seeded().count, "seeded with the starter command set")
        XCTAssertEqual(store.favorites.schemaVersion, Favorites.currentSchemaVersion, "marked migrated")
        // And idempotent: a reload does not add a second AI band.
        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.favorites.bands.filter { AIBand.isAIBand($0) }.count, 1)
    }

    func testAICommandMovesBetweenBands() {
        // Spec: "An AI command moves between bands" / "movable between bands like any other item."
        let store = FavoritesStore(defaults: makeDefaults())
        let dev = store.addBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1))
        let work = store.addBand(name: "Work", color: ItemColor(red: 0, green: 1, blue: 0))
        let cmd = command("Fix")
        let item = AIBand.item(for: cmd)
        store.addItem(item, toBand: dev)
        XCTAssertTrue(store.favorites.bands.first { $0.id == dev }!.items.contains { $0.id == item.id })

        store.moveItem(item.id, fromBand: dev, toBand: work)

        XCTAssertFalse(store.favorites.bands.first { $0.id == dev }!.items.contains { $0.id == item.id },
                       "the item left the source band")
        let moved = store.favorites.bands.first { $0.id == work }!.items.first { $0.id == item.id }
        XCTAssertNotNil(moved, "the item appears in the destination band")
        guard case let .aiCommand(c)? = moved?.kind else { return XCTFail("kind preserved as .aiCommand") }
        XCTAssertEqual(c, cmd, "the embedded command survives the move")
    }

    func testMigrationWithEmptyLegacyRecordAddsNoAIBand() {
        let defaults = makeDefaults()
        writeV1Favorites([ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1))], to: defaults)
        writeLegacyCommands([], to: defaults)   // opted in once, but no commands

        let store = FavoritesStore(defaults: defaults)
        XCTAssertFalse(store.favorites.bands.contains { AIBand.isAIBand($0) },
                       "an empty legacy record imports nothing")
        XCTAssertNil(defaults.data(forKey: "aiCommands"), "the empty legacy key is still retired")
    }

    func testMigrationDoesNotDuplicateWhenAIBandAlreadyPresent() {
        // Defensive idempotency: a v1 record that somehow already has an AI band must not get a second.
        let defaults = makeDefaults()
        let existingAI = AIBand.band(from: [command("Existing")])
        writeV1Favorites([existingAI], to: defaults)
        writeLegacyCommands([command("Legacy")], to: defaults)

        let store = FavoritesStore(defaults: defaults)
        let aiBands = store.favorites.bands.filter { AIBand.isAIBand($0) }
        XCTAssertEqual(aiBands.count, 1, "never appends a second AI band")
        XCTAssertEqual(aiBands.first?.items.map(\.title), ["Existing"], "keeps the existing AI band as-is")
    }
}
