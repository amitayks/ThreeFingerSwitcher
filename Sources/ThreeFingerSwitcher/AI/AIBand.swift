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
    /// The "AI" band's default launcher icon (the band list shows icons, not names).
    static let icon: ItemIcon = .sfSymbol("wand.and.stars")

    /// One `.aiCommand` band item for a command. The item's id mirrors the command id (stable SwiftUI
    /// identity + the executor keys on it), and its title/icon/tint mirror the command for rendering.
    static func item(for command: AICommand) -> LaunchItem {
        LaunchItem(id: command.id, title: command.name, icon: command.icon,
                   tint: command.tint, kind: .aiCommand(command))
    }

    /// Build the "AI" band from a list of commands (used by seeding + migration).
    static func band(from commands: [AICommand]) -> ContextBand {
        ContextBand(id: bandID, name: name, color: color, icon: icon, items: commands.map(item(for:)))
    }

    /// True for a band carrying the AI sentinel id (used by the migration's idempotency check).
    static func isAIBand(_ band: ContextBand) -> Bool { band.id == bandID }

    /// The default AI command set shipped on a fresh install: a curated subset of the shipped
    /// `AICommandCatalog` — the canned verbs that cover the common cases, each with a sensible prompt
    /// template. In-place transforms confirm OFF; add-to-calendar (side-effecting) confirms ON. The
    /// full catalog is browsable from the Hub; the curation lives in `AICommandCatalog.seeded()`.
    static func seeded() -> [AICommand] { AICommandCatalog.seeded() }

    /// The seeded "AI" band for a fresh favorites record.
    static func seededBand() -> ContextBand { band(from: seeded()) }
}
