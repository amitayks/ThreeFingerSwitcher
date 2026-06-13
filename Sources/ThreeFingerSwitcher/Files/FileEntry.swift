import Foundation

/// The Files-band filesystem data model.
///
/// Like `LaunchItem` and `ClipboardEntry`, everything here is a pure value type with **no AppKit/SwiftUI
/// dependency**, so the navigation / listing / open logic that consumes it stays unit-testable without a
/// running app or a live filesystem. Turning a directory listing into `FileEntry`s (reading resource
/// values off a `URL`) lives in the boundary layer (`DirectoryLister`); choosing a row glyph for a
/// `FileKind` lives in the view layer.
///
/// A `FileEntry` is **ephemeral**: the Files band is rebuilt from the live filesystem on every launcher
/// open and is **never persisted** into the authored favorites. Like `ClipboardEntry` (which the Files
/// band is modeled on, design D2), ephemerality is enforced at the **persistence boundary** — the
/// `FilesBandBuilder` produces synthetic items and the favorites store never sees them — not by refusing
/// `Codable`: the enclosing `LaunchItemKind.fileEntry` case lives on a `Codable` enum, so the payload must
/// itself be `Codable` for that synthesis to hold, exactly as `ClipboardEntry` is.

/// A coarse, AppKit-free classification of an entry, just rich enough to pick a row glyph. The boundary
/// layer derives this from the entry's `UTType` (a directory becomes `.folder` regardless of its UTI);
/// the mapping from a `FileKind` to a concrete SF Symbol stays in the view layer so this stays
/// dependency-light.
enum FileKind: String, Codable, Equatable, CaseIterable {
    case folder
    case image
    case audio
    case video
    case pdf
    case archive
    case sourceCode
    case text
    case application
    /// Anything not matched above (the neutral document glyph).
    case other
}

/// One filesystem entry in a listed folder: a **stable identity derived from the absolute path** plus the
/// handful of fields the column navigator needs to display and act on it.
///
/// The id is the file's **standardized absolute path** (not a fresh `UUID`): re-listing the same folder —
/// on re-entry, or because a file changed on disk — yields the **same** id for the same path, so the
/// SwiftUI selection highlight keeps a stable target and never strobes or jumps (design D2). This mirrors
/// how `ClipboardBandBuilder` reuses `ClipboardEntry.id` as the `LaunchItem.id` for stable identity across
/// rebuilds — here the stable value is path-derived rather than capture-assigned, because the same file
/// has no persistent UUID of its own.
struct FileEntry: Codable, Equatable, Identifiable {
    /// Stable identity: the entry's standardized absolute path. Two listings of the same path produce
    /// equal ids; a downstream `LaunchItem` reuses this so re-listings don't restart the highlight.
    let id: String
    /// The file URL this entry refers to (a `fileURL`, standardized).
    let url: URL
    /// Display name shown in the list column (the URL's last path component).
    let name: String
    /// True for a directory (drives descend vs. open-in-default and the preview target).
    let isDirectory: Bool
    /// Last content-modification date, when the filesystem reported one (nil if unavailable).
    let modificationDate: Date?
    /// Coarse type used to choose a row glyph.
    let kind: FileKind

    /// The entry's absolute path, derived from `url`. (Equal to `id`.)
    var path: String { url.path }

    init(url: URL, name: String, isDirectory: Bool, modificationDate: Date?, kind: FileKind) {
        let standardized = url.standardizedFileURL
        self.id = standardized.path
        self.url = standardized
        self.name = name
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.kind = kind
    }

    // MARK: Codable
    //
    // Required only so the enclosing `Codable` `LaunchItemKind.fileEntry` synthesizes (see the type doc);
    // `FileEntry`s are never actually written to the favorites store. `id`/`path` are derived, not stored,
    // so decoding rebuilds the value through the standardizing memberwise init — this re-derives `id`
    // from `url` and keeps the `id == url.standardizedFileURL.path` invariant rather than trusting a
    // separately-encoded id.
    private enum CodingKeys: String, CodingKey {
        case url, name, isDirectory, modificationDate, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try c.decode(URL.self, forKey: .url),
            name: try c.decode(String.self, forKey: .name),
            isDirectory: try c.decode(Bool.self, forKey: .isDirectory),
            modificationDate: try c.decodeIfPresent(Date.self, forKey: .modificationDate),
            kind: try c.decode(FileKind.self, forKey: .kind)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(name, forKey: .name)
        try c.encode(isDirectory, forKey: .isDirectory)
        try c.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try c.encode(kind, forKey: .kind)
    }
}
