import Foundation
import Combine

/// Persists the configured `[AICommand]` as a single versioned JSON blob in `UserDefaults`, under a
/// key that is SEPARATE from Favorites (spec: "Commands are not written into Favorites" — a command
/// is configuration, not a Favorites item).
///
/// Mirrors `FavoritesStore`'s house pattern: an injectable `UserDefaults` (tests use an isolated
/// suite), a `@Published` model, and a `mutate` funnel so every edit persists immediately and the
/// editor/overlay are notified. On first use the default command set is seeded; pre-feature data
/// (no key) decodes to an empty list (NOT seeded), so the band stays absent until the user opts in.
@MainActor
final class AICommandStore: ObservableObject {
    static let shared = AICommandStore()

    /// Bumped when the on-disk shape changes; drives forward migration.
    static let currentSchemaVersion = 1

    private let defaults: UserDefaults
    /// Distinct from FavoritesStore's "favorites" key — commands live in their own record.
    private let key = "aiCommands"

    @Published private(set) var commands: [AICommand]

    private convenience init() { self.init(defaults: .standard) }

    /// Test/seam initializer: inject an isolated `UserDefaults`. Loads the stored record (migrating
    /// older schema versions forward) or seeds the default command set on first run.
    ///
    /// - Parameter seedIfMissing: when no record exists, seed the default set (`true`, the default)
    ///   or start empty (`false`). Empty stays empty either way — only a *missing* record is seeded.
    init(defaults: UserDefaults, seedIfMissing: Bool = true) {
        self.defaults = defaults
        if let loaded = Self.load(from: defaults, key: key) {
            self.commands = loaded
        } else {
            let seed = seedIfMissing ? Self.seeded() : []
            self.commands = seed
            // Persist the SAME instances held in memory (not a second seeded() call, which would
            // mint different UUIDs) so command ids are stable across the seed→reload boundary —
            // AICommand is Identifiable and the band/editor key on id.
            Self.save(seed, to: defaults, key: key)
        }
    }

    // MARK: - Mutation

    /// Apply an edit and persist it immediately. All editor paths funnel through here.
    func mutate(_ block: (inout [AICommand]) -> Void) {
        var copy = commands
        block(&copy)
        commands = copy
        save()
    }

    /// Append a command (used by the editor's add affordance).
    func add(_ command: AICommand) {
        mutate { $0.append(command) }
    }

    /// Replace a command in place by id (a field edit). No-op if the id is unknown.
    func update(_ command: AICommand) {
        mutate { list in
            guard let i = list.firstIndex(where: { $0.id == command.id }) else { return }
            list[i] = command
        }
    }

    /// Remove a command by id.
    func remove(_ id: UUID) {
        mutate { $0.removeAll { $0.id == id } }
    }

    /// Reorder commands (matches the editor's drag-to-reorder).
    func move(fromOffsets: IndexSet, toOffset: Int) {
        mutate { $0.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    /// Look up a command by id.
    func command(withID id: UUID) -> AICommand? {
        commands.first { $0.id == id }
    }

    func save() {
        Self.save(commands, to: defaults, key: key)
    }

    // MARK: - Persistence

    /// The on-disk record: a version stamp plus the ordered command list.
    private struct Stored: Codable {
        var schemaVersion: Int
        var commands: [AICommand]
    }

    private static func load(from defaults: UserDefaults, key: String) -> [AICommand]? {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return migrate(decoded).commands
    }

    private static func save(_ commands: [AICommand], to defaults: UserDefaults, key: String) {
        let record = Stored(schemaVersion: currentSchemaVersion, commands: commands)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    /// Forward-migrate an older record to the current schema. Identity for v1; future versions branch
    /// here. Always stamps the current version so a re-save is normalized.
    private static func migrate(_ record: Stored) -> Stored {
        var record = record
        // (No migrations yet — v1 is current.)
        record.schemaVersion = currentSchemaVersion
        return record
    }

    // MARK: - Seed

    /// The default command set shipped on first use (design D5 / tasks 7.4): the canned verbs that
    /// cover the common cases, each with a sensible prompt template. In-place transforms confirm OFF;
    /// add-to-calendar (side-effecting) confirms ON by default.
    static func seeded() -> [AICommand] {
        [
            AICommand(
                name: "Fix Grammar",
                icon: .sfSymbol("text.badge.checkmark"),
                tint: ItemColor(red: 0.25, green: 0.72, blue: 0.40),
                input: .selection,
                promptTemplate: "Fix the spelling and grammar of the following text. Return only the corrected text, with no commentary:\n\n{input}",
                output: .replaceSelection
            ),
            AICommand(
                name: "Make Concise",
                icon: .sfSymbol("scissors"),
                tint: ItemColor(red: 0.20, green: 0.48, blue: 0.93),
                input: .selection,
                promptTemplate: "Rewrite the following text to be as concise as possible while preserving its meaning. Return only the rewritten text:\n\n{input}",
                output: .replaceSelection
            ),
            AICommand(
                name: "Translate",
                icon: .sfSymbol("character.bubble"),
                tint: ItemColor(red: 0.66, green: 0.36, blue: 0.86),
                input: .selection,
                promptTemplate: "Translate the following text to English. Return only the translation:\n\n{input}",
                output: .replaceSelection
            ),
            AICommand(
                name: "Explain",
                icon: .sfSymbol("lightbulb"),
                tint: ItemColor(red: 0.95, green: 0.70, blue: 0.20),
                input: .selection,
                promptTemplate: "Explain the following clearly and concisely for a curious non-expert:\n\n{input}",
                output: .previewOnly
            ),
            AICommand(
                name: "Summarize",
                icon: .sfSymbol("text.line.first.and.arrowtriangle.forward"),
                tint: ItemColor(red: 0.30, green: 0.62, blue: 0.78),
                input: .selection,
                promptTemplate: "Summarize the following in a few short bullet points:\n\n{input}",
                output: .previewOnly
            ),
            AICommand(
                name: "Add to Calendar",
                icon: .sfSymbol("calendar.badge.plus"),
                tint: ItemColor(red: 0.90, green: 0.30, blue: 0.30),
                input: .selection,
                promptTemplate: "Extract a calendar event from the following text. Today is {date}. If the text does not describe an event, decline.\n\n{input}",
                output: .runTask(.addToCalendar)
                // confirmBeforeRun derives to true (side-effecting) at creation.
            )
        ]
    }
}
