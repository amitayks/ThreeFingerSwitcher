import Foundation

/// The "AI" band: a NORMAL, editable favorites band that holds `.aiCommand` items (configuration-hub
/// fold-in). This replaces the former *synthetic* `AICommandBandBuilder` — AI commands are no longer
/// projected fresh on every launcher open from a separate store; they are first-class, persisted band
/// items that can live in **any** band. This helper exists only to (a) build the seeded "AI" band on a
/// fresh install and (b) fold a legacy `AICommandStore` record into a normal band on upgrade.
enum AIBand {
    /// Stable id reused from the former synthetic band, so the seed/migration are recognizable and the
    /// migration is idempotent (it never appends a second "AI" band). After fold-in this is just a
    /// normal band id — the user may rename, recolor, reorder, split, or delete the band.
    static let bandID = UUID(uuidString: "A1C0AAAA-0000-4000-8000-000000000001")!
    static let name = "AI"
    static let color = ItemColor(red: 0.55, green: 0.40, blue: 0.92)

    /// One `.aiCommand` band item for a command. The item's id mirrors the command id (stable SwiftUI
    /// identity + the executor keys on it), and its title/icon/tint mirror the command for rendering.
    static func item(for command: AICommand) -> LaunchItem {
        LaunchItem(id: command.id, title: command.name, icon: command.icon,
                   tint: command.tint, kind: .aiCommand(command))
    }

    /// Build the "AI" band from a list of commands (used by seeding + migration).
    static func band(from commands: [AICommand]) -> ContextBand {
        ContextBand(id: bandID, name: name, color: color, items: commands.map(item(for:)))
    }

    /// True for a band carrying the AI sentinel id (used by the migration's idempotency check).
    static func isAIBand(_ band: ContextBand) -> Bool { band.id == bandID }

    /// The default AI command set shipped on a fresh install (moved here from the former
    /// `AICommandStore.seeded()`): the canned verbs that cover the common cases, each with a sensible
    /// prompt template. In-place transforms confirm OFF; add-to-calendar (side-effecting) confirms ON.
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

    /// The seeded "AI" band for a fresh favorites record.
    static func seededBand() -> ContextBand { band(from: seeded()) }
}
