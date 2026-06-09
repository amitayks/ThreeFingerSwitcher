import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the synthetic AI-command band (spec ai-command-band: "Synthetic AI command band"): the
/// band is present only when the opt-in is on AND commands exist, absent otherwise, carries the
/// sentinel id, is built from the configured commands (in order), and is never written into the
/// persisted Favorites record. Mirrors the Clipboard-band builder's contract.
@MainActor
final class AICommandBandBuilderTests: XCTestCase {

    private func command(_ name: String) -> AICommand {
        AICommand(name: name, icon: .sfSymbol("sparkles"),
                  tint: ItemColor(red: 0.5, green: 0.4, blue: 0.9),
                  input: .selection, promptTemplate: "{input}", output: .previewOnly)
    }

    // MARK: - Presence gating

    func testPresentOnlyWhenOptedInAndCommandsExist() {
        let cmds = [command("Fix"), command("Summarize")]
        XCTAssertTrue(AICommandBandBuilder.shouldPresent(optedIn: true, commands: cmds),
                      "opt-in on + commands present ⇒ band shown")
        XCTAssertFalse(AICommandBandBuilder.shouldPresent(optedIn: false, commands: cmds),
                       "opt-in off ⇒ band absent even with commands")
        XCTAssertFalse(AICommandBandBuilder.shouldPresent(optedIn: true, commands: []),
                       "no commands ⇒ band absent even when opted in")
        XCTAssertFalse(AICommandBandBuilder.shouldPresent(optedIn: false, commands: []),
                       "off + empty ⇒ absent")
    }

    // MARK: - Build from commands

    func testBuildProjectsCommandsInOrderWithSentinelID() {
        let cmds = [command("Fix"), command("Translate"), command("Explain")]
        let band = AICommandBandBuilder.build(from: cmds)

        XCTAssertEqual(band.id, AICommandBandBuilder.bandID, "carries the sentinel band id")
        XCTAssertTrue(AICommandBandBuilder.isAICommandBand(band), "recognized by its sentinel id")
        XCTAssertEqual(band.items.map(\.title), ["Fix", "Translate", "Explain"],
                       "items follow the configured command order")
        // Each item is an `.aiCommand` carrying the source command, with the command's id as the item id.
        for (item, cmd) in zip(band.items, cmds) {
            XCTAssertEqual(item.id, cmd.id, "item id mirrors the command id (stable SwiftUI identity)")
            guard case let .aiCommand(carried) = item.kind else {
                return XCTFail("each item is an .aiCommand")
            }
            XCTAssertEqual(carried, cmd, "the source command round-trips into the item kind")
            XCTAssertEqual(item.tint, cmd.tint, "the command tint is carried for rendering")
        }
    }

    func testBuildFromStoreCommands() {
        // An isolated store seeded with the default command set; the band is projected from it.
        let suite = "AICommandBandBuilderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AICommandStore(defaults: defaults)
        XCTAssertFalse(store.commands.isEmpty, "the store seeds a default command set")

        let band = AICommandBandBuilder.build(from: store.commands)
        XCTAssertEqual(band.items.count, store.commands.count, "the band has one item per command")
        XCTAssertEqual(band.items.map(\.title), store.commands.map(\.name),
                       "the band reflects the current store contents/order")
    }

    // MARK: - Never written to Favorites

    func testAICommandBandIsNeverPersistedIntoFavorites() {
        // The synthetic band is a fire-time projection: it must NOT appear in the persisted Favorites
        // record, exactly like the Clipboard band.
        let suite = "AICommandBandBuilderTests.fav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = FavoritesStore(defaults: defaults)

        XCTAssertFalse(favorites.favorites.bands.contains { AICommandBandBuilder.isAICommandBand($0) },
                       "no AI band in the freshly-seeded favorites")
        // Building the synthetic band does not touch the store.
        _ = AICommandBandBuilder.build(from: [command("Fix")])
        XCTAssertFalse(favorites.favorites.bands.contains { AICommandBandBuilder.isAICommandBand($0) },
                       "building the synthetic band never writes it into Favorites")
        XCTAssertFalse(favorites.favorites.bands.contains { $0.id == AICommandBandBuilder.bandID })
    }

    // MARK: - Sentinel distinct from the Clipboard band

    func testAISentinelIsDistinctFromClipboardSentinel() {
        XCTAssertNotEqual(AICommandBandBuilder.bandID, ClipboardBandBuilder.bandID,
                          "the AI and Clipboard synthetic bands have distinct sentinel ids")
        let aiBand = AICommandBandBuilder.build(from: [command("Fix")])
        XCTAssertFalse(ClipboardBandBuilder.isClipboardBand(aiBand),
                       "the AI band is not mistaken for the Clipboard band")
    }
}
