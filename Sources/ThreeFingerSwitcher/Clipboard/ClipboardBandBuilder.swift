import Foundation

/// Builds the **synthetic, ephemeral** Clipboard band shown as the last launcher band. The band is
/// rebuilt on every launcher open from `ClipboardStore.recentWindow` (recent slice, pinned-first);
/// it is never written into the persisted `Favorites` record and is never the home band.
///
/// Each entry becomes a `LaunchItem` whose kind is `.clipboardEntry`, so it flows through the existing
/// `LauncherModel` / dwell / lift plumbing unchanged. The item id mirrors the entry id, giving stable
/// SwiftUI identity across rebuilds.
enum ClipboardBandBuilder {
    /// Sentinel band id so the overlay can recognize the Clipboard band among the favorites bands.
    static let bandID = UUID(uuidString: "C11B0A12-0000-4000-8000-000000000001")!
    static let name = "Clipboard"
    static let color = ItemColor(red: 0.86, green: 0.62, blue: 0.20)
    /// The Clipboard band's dedicated, preset launcher icon (not user-editable — it's a synthetic band).
    static let icon: ItemIcon = .sfSymbol("clipboard.fill")

    static func build(from entries: [ClipboardEntry]) -> ContextBand {
        let items = entries.map { entry in
            LaunchItem(id: entry.id, title: entry.key, icon: glyph(for: entry.kind),
                       kind: .clipboardEntry(entry))
        }
        return ContextBand(id: bandID, name: name, color: color, icon: icon, items: items)
    }

    /// True for a band produced by this builder (matched by the sentinel id).
    static func isClipboardBand(_ band: ContextBand) -> Bool { band.id == bandID }

    /// SF Symbol glyph standing in for each kind in the key column / fallback icon.
    static func glyph(for kind: ClipboardKind) -> ItemIcon {
        switch kind {
        case .text:     return .sfSymbol("text.alignleft")
        case .richText: return .sfSymbol("textformat")
        case .image:    return .sfSymbol("photo")
        case .file:     return .sfSymbol("doc")
        case .color:    return .sfSymbol("paintpalette")
        case .url:      return .sfSymbol("link")
        }
    }
}
