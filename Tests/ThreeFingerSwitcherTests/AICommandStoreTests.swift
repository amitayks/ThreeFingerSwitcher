import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the AI command store (spec: "Commands persist across launches" / "Commands are not
/// written into Favorites"): persistence + ordering round-trip, default-set seeding on first use,
/// and that pre-feature data (no key) decodes to an empty list rather than seeding.
@MainActor
final class AICommandStoreTests: XCTestCase {

    /// An isolated `UserDefaults` suite so tests don't touch the real one.
    private func isolatedDefaults() -> UserDefaults {
        let suite = "tfs-aicommand-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Seeding

    func testSeedsDefaultSetOnFirstUse() {
        let store = AICommandStore(defaults: isolatedDefaults())
        XCTAssertFalse(store.commands.isEmpty, "the default command set is seeded on first use")
        let names = store.commands.map(\.name)
        XCTAssertTrue(names.contains("Fix Grammar"))
        XCTAssertTrue(names.contains("Add to Calendar"))
        // The side-effecting seed defaults confirm ON.
        let calendar = store.commands.first { $0.name == "Add to Calendar" }
        XCTAssertEqual(calendar?.confirmBeforeRun, true,
                       "the seeded calendar command defaults confirmBeforeRun ON")
    }

    func testSeededIdsAreStableAcrossReload() {
        // Regression: the seed must persist the SAME instances kept in memory, so command ids are
        // identical between the seeding store and a fresh store loaded over the same defaults
        // (AICommand is Identifiable; the band/editor key on id — divergent ids would break selection).
        let defaults = isolatedDefaults()
        let seeding = AICommandStore(defaults: defaults)
        let reloaded = AICommandStore(defaults: defaults)
        XCTAssertEqual(seeding.commands.map(\.id), reloaded.commands.map(\.id),
                       "seeded command ids are stable across the seed→reload boundary")
    }

    func testMissingKeyWithSeedingDisabledDecodesToEmpty() {
        // Pre-feature data: no AI key present, seeding suppressed → empty list (band stays absent).
        let store = AICommandStore(defaults: isolatedDefaults(), seedIfMissing: false)
        XCTAssertTrue(store.commands.isEmpty,
                      "older data with no AI key decodes to an empty command list")
    }

    // MARK: - Persistence across "launches"

    func testCommandsPersistAcrossLaunches() {
        let defaults = isolatedDefaults()
        let first = AICommandStore(defaults: defaults, seedIfMissing: false)
        first.add(AICommand(name: "One", icon: .emoji("1️⃣"), input: .selection,
                            promptTemplate: "{input}", output: .previewOnly))
        first.add(AICommand(name: "Two", icon: .emoji("2️⃣"), input: .clipboard,
                            promptTemplate: "{input}", output: .pasteAtCursor))

        // A fresh store over the same defaults simulates a relaunch.
        let second = AICommandStore(defaults: defaults)
        XCTAssertEqual(second.commands.map(\.name), ["One", "Two"],
                       "the same commands, in the same order, are present after a relaunch")
    }

    func testOrderingIsPreservedThroughReorder() {
        let store = AICommandStore(defaults: isolatedDefaults(), seedIfMissing: false)
        let a = AICommand(name: "A", icon: .emoji("🅰️"), input: .none, promptTemplate: "{date}", output: .previewOnly)
        let b = AICommand(name: "B", icon: .emoji("🅱️"), input: .none, promptTemplate: "{date}", output: .previewOnly)
        let c = AICommand(name: "C", icon: .emoji("🅲"), input: .none, promptTemplate: "{date}", output: .previewOnly)
        store.add(a); store.add(b); store.add(c)

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)   // A to the end
        XCTAssertEqual(store.commands.map(\.name), ["B", "C", "A"])
    }

    func testUpdateAndRemovePersist() {
        let defaults = isolatedDefaults()
        let store = AICommandStore(defaults: defaults, seedIfMissing: false)
        var cmd = AICommand(name: "Edit me", icon: .emoji("✏️"), input: .selection,
                            promptTemplate: "old", output: .previewOnly)
        store.add(cmd)

        cmd.promptTemplate = "new"
        store.update(cmd)
        XCTAssertEqual(AICommandStore(defaults: defaults).command(withID: cmd.id)?.promptTemplate,
                       "new", "an edit persists immediately and survives a relaunch")

        store.remove(cmd.id)
        XCTAssertNil(AICommandStore(defaults: defaults, seedIfMissing: false).command(withID: cmd.id),
                     "a removal persists")
    }

    // MARK: - Separation from Favorites

    func testStoreUsesDistinctKeyFromFavorites() {
        // The AI store must not write under the favorites key (spec: not in the Favorites record).
        let defaults = isolatedDefaults()
        let store = AICommandStore(defaults: defaults, seedIfMissing: false)
        store.add(AICommand(name: "X", icon: .emoji("✨"), input: .none,
                            promptTemplate: "{date}", output: .previewOnly))
        XCTAssertNil(defaults.data(forKey: "favorites"),
                     "AI commands are stored under their own key, not 'favorites'")
        XCTAssertNotNil(defaults.data(forKey: "aiCommands"))
    }
}
