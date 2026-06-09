import Foundation

/// Builds the **synthetic, ephemeral** AI-command band shown as a launcher band (spec
/// ai-command-band: "Synthetic AI command band"). Mirrors `ClipboardBandBuilder`: rebuilt on every
/// launcher open from `AICommandStore.commands`, never written into the persisted `Favorites` record,
/// and never the home band.
///
/// Each configured `AICommand` becomes a `LaunchItem` whose kind is `.aiCommand`, so it flows through
/// the existing `LauncherModel` / dwell / lift plumbing unchanged (firing then diverts to the
/// streaming preview canvas instead of dismissing — see `LauncherOverlayController`). The item id
/// mirrors the command id, giving stable SwiftUI identity across rebuilds.
enum AICommandBandBuilder {
    /// Sentinel band id so the overlay can recognize the AI-command band among the favorites bands.
    static let bandID = UUID(uuidString: "A1C0AAAA-0000-4000-8000-000000000001")!
    static let name = "AI"
    static let color = ItemColor(red: 0.55, green: 0.40, blue: 0.92)

    /// Project the configured commands into a synthetic band. The caller decides WHETHER to include
    /// it (`shouldPresent`); this just renders the items in the configured order.
    static func build(from commands: [AICommand]) -> ContextBand {
        let items = commands.map { command in
            LaunchItem(id: command.id, title: command.name, icon: command.icon,
                       tint: command.tint, kind: .aiCommand(command))
        }
        return ContextBand(id: bandID, name: name, color: color, items: items)
    }

    /// Whether the AI band should appear at all: the opt-in is on AND at least one command exists
    /// (spec: "absent entirely when the opt-in is off or no commands are configured").
    static func shouldPresent(optedIn: Bool, commands: [AICommand]) -> Bool {
        optedIn && !commands.isEmpty
    }

    /// True for a band produced by this builder (matched by the sentinel id).
    static func isAICommandBand(_ band: ContextBand) -> Bool { band.id == bandID }
}
