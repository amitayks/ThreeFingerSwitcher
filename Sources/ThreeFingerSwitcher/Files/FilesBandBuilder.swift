import Foundation
import CryptoKit

/// Builds the **synthetic, ephemeral** Files band shown as a launcher band alongside the authored
/// favorites and the synthetic Clipboard band. The band is projected fresh on every launcher open from
/// the *current* directory column (the navigator's `visibleEntries`); it is never written into the
/// persisted `Favorites` record and is never the home band — exactly like `ClipboardBandBuilder`.
///
/// Each `FileEntry` becomes a `LaunchItem` whose kind is `.fileEntry`, so the band flows through the
/// existing `LauncherModel` plumbing as data. (A chosen entry is **not** resolved through the generic
/// `LaunchService.fire` — see that case's no-op — but through the Files band's own drill-down / open
/// path: folders descend in place, files open via `FileOpenService`. That path is owned by the Files
/// band's dedicated views/coordination, not this builder.)
///
/// **Stable identity (design D2).** A `LaunchItem.id` is a `UUID`, but a `FileEntry.id` is its
/// standardized absolute *path* `String`. Re-listing the same folder must yield the **same** item id
/// for the same path, or the SwiftUI selection highlight strobes/jumps on every re-list. We therefore
/// derive a **deterministic** UUID from the path (`uuid(forPath:)`) rather than minting a fresh one —
/// mirroring how `ClipboardBandBuilder` reuses `ClipboardEntry.id` as the `LaunchItem.id`, except the
/// stable value here is path-derived because a file has no persistent UUID of its own.
enum FilesBandBuilder {
    /// Sentinel band id so the overlay can recognize the Files band among the launcher's bands
    /// (distinct from `ClipboardBandBuilder.bandID` and `AIBand.bandID`). "F11E5" ≈ "FILES".
    static let bandID = UUID(uuidString: "F11E5000-0000-4000-8000-000000000001")!
    static let name = "Files"
    /// The Files band's accent tint as a default, AppKit-free `ItemColor` matching the calm blue
    /// `AppSettings.Defaults.filesBandTint` (`#3B82C4`). The user-configurable `filesBandTint` hex is
    /// resolved to a `Color`/`ItemColor` at the view/overlay boundary (a later wiring stage); this is the
    /// neutral fallback used when the builder runs without that context. `#3B82C4` = (59, 130, 196)/255.
    static let color = ItemColor(red: 0.231, green: 0.510, blue: 0.769)
    /// The Files band's dedicated, preset launcher icon (not user-editable — it's a synthetic band).
    static let icon: ItemIcon = .sfSymbol("folder.fill")

    /// Build the Files band from the current directory column's entries (already sorted by the
    /// navigator). Each entry maps to a `.fileEntry` `LaunchItem` with a path-stable id and a
    /// `FileKind`-derived glyph; the band itself carries the synthetic sentinel id.
    static func build(currentColumn entries: [FileEntry]) -> ContextBand {
        let items = entries.map { item(for: $0) }
        return ContextBand(id: bandID, name: name, color: color, icon: icon, items: items)
    }

    /// One `.fileEntry` band item for a filesystem entry. The item id is derived deterministically from
    /// the entry's path (`uuid(forPath:)`) so re-listings keep a stable SwiftUI identity; the title is
    /// the entry's display name and the icon is a `FileKind`-derived SF Symbol (`glyph(for:)`).
    static func item(for entry: FileEntry) -> LaunchItem {
        LaunchItem(id: uuid(forPath: entry.id), title: entry.name,
                   icon: glyph(for: entry.kind), kind: .fileEntry(entry))
    }

    /// True for a band produced by this builder (matched by the sentinel id).
    static func isFilesBand(_ band: ContextBand) -> Bool { band.id == bandID }

    // MARK: - Stable path → UUID

    /// Derive a **stable, deterministic** `UUID` from a file path (the entry's standardized absolute
    /// path / `FileEntry.id`). The same path always produces the same UUID, so a `.fileEntry` item keeps
    /// its SwiftUI identity across re-lists (no highlight strobe, design D2); different paths effectively
    /// never collide (128-bit SHA-256 prefix). Implemented as the first 16 bytes of `SHA256(path)` —
    /// CryptoKit is already a Core dependency (see `ModelManager`). The version/variant bits are left as
    /// the hash produced them (this is an internal identity token, not an RFC-4122-typed UUID), exactly
    /// the way other stable identities are derived from content here.
    static func uuid(forPath path: String) -> UUID {
        let digest = SHA256.hash(data: Data(path.utf8))
        var bytes = [UInt8](digest)            // 32 bytes; take the first 16 for the UUID
        bytes.removeLast(bytes.count - 16)
        return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                           bytes[4],  bytes[5],  bytes[6],  bytes[7],
                           bytes[8],  bytes[9],  bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Glyphs

    /// The SF Symbol standing in for a `FileKind`, used as the `.fileEntry` item's launcher icon (the
    /// view's `.sfSymbol` branch renders it). Mirrors `ClipboardBandBuilder.glyph(for:)`. The Files
    /// band's own column/preview views may show richer, real file icons; this is the AppKit-free,
    /// kind-coarse fallback carried on the model item.
    static func glyph(for kind: FileKind) -> ItemIcon {
        switch kind {
        case .folder:      return .sfSymbol("folder.fill")
        case .image:       return .sfSymbol("photo")
        case .audio:       return .sfSymbol("music.note")
        case .video:       return .sfSymbol("film")
        case .pdf:         return .sfSymbol("doc.richtext")
        case .archive:     return .sfSymbol("doc.zipper")
        case .sourceCode:  return .sfSymbol("chevron.left.forwardslash.chevron.right")
        case .text:        return .sfSymbol("doc.text")
        case .application: return .sfSymbol("app")
        case .other:       return .sfSymbol("doc")
        }
    }
}
