import Foundation
import UniformTypeIdentifiers

/// The Files band's directory-listing boundary: it reads ONE folder's **local** contents off the live
/// filesystem and turns each `URL` into a pure `FileEntry`. This is the only place that touches
/// `FileManager` (the navigation model stays pure and is fed the resulting entries), so it is also the
/// place that maps a `FileManager`/OS read failure into the shared `FileActionError` taxonomy — Core
/// above it never sees a raw `NSError`.
///
/// **Off the main thread (spec):** the read runs on a detached `userInitiated` task so opening a large
/// folder never blocks the UI. The call is `async throws` — a non-throwing return yields the listed
/// entries; a throwing return is a clean `FileActionError.folderUnreadable` whose raw OS text rides only
/// on the opt-in `details` payload (and logs), never the headline.
///
/// **Local only (spec / design D9):** the listing requests `URLResourceValues` and **skips** any entry
/// the filesystem reports as a non-local / iCloud-placeholder item, so navigation never blocks on (or
/// descends into) a network or yet-to-download location. Hidden files are skipped via
/// `.skipsHiddenFiles`, mirroring how `loadInstalledApps` keeps the shallow scan to user-facing items.
///
/// **Stable order (spec):** entries come back sorted by the supplied `FilesSortOrder` so a re-list of the
/// same folder yields the same order (the path-derived `FileEntry.id` keeps the highlight stable across
/// re-lists). The folder may itself be re-listed at any time; nothing here is cached.
struct DirectoryLister {
    /// The resource values the listing pulls per entry — exactly the spec's "is-directory, modification
    /// date, regular-file", plus `.contentType` (to pick a `FileKind` row glyph) and the locality keys
    /// used to drop non-local / iCloud-placeholder items at the boundary. Requesting them up front (via
    /// `includingPropertiesForKeys:`) lets the filesystem prefetch them, so `resourceValues(forKeys:)`
    /// per entry is cheap.
    private static let prefetchKeys: [URLResourceKey] = [
        .isDirectoryKey, .contentModificationDateKey, .isRegularFileKey,
        .contentTypeKey, .isUbiquitousItemKey, .nameKey,
    ]

    /// The `Set` form used for the per-entry `resourceValues(forKeys:)` read.
    private static let readKeys: Set<URLResourceKey> = Set(prefetchKeys)

    init() {}

    /// List `folder`'s **local** contents, sorted by `order`, off the main thread.
    ///
    /// Maps a read failure into `FileActionError.folderUnreadable(name:details:)` at this boundary (the
    /// raw `FileManager`/OS error becomes the opt-in `details`, never the headline). The detached task is
    /// `userInitiated`; the body is pure-Foundation, so it is safe to run off the actor.
    func contents(of folder: URL, sortedBy order: FilesSortOrder) async throws -> [FileEntry] {
        try await Task.detached(priority: .userInitiated) {
            try Self.read(folder, order: order)
        }.value
    }

    /// The synchronous read body (extracted so it is exercisable directly and runs on the detached task).
    /// `nonisolated`/`static` and free of any actor state — it only reads `FileManager`.
    private static func read(_ folder: URL, order: FilesSortOrder) throws -> [FileEntry] {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: prefetchKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            // Map at the boundary: the raw FileManager/OS error never escapes into feature/UI code — it
            // is stringified into the opt-in `details` here (the only place it survives, off the headline).
            throw FileActionError.folderUnreadable(name: displayName(of: folder),
                                                   details: String(describing: error))
        }

        let entries = urls.compactMap(entry(for:))
        return order.sorted(entries)
    }

    /// Turn one listed `URL` into a `FileEntry`, or `nil` when it should be skipped (a non-local /
    /// iCloud-placeholder item, per the local-only scope). Reads the per-entry resource values; an entry
    /// whose values can't be read is treated as a plain file (it still lists, just without rich metadata)
    /// rather than dropped, so a transient stat hiccup doesn't make a row vanish.
    private static func entry(for url: URL) -> FileEntry? {
        let values = try? url.resourceValues(forKeys: readKeys)

        // Local-only: drop iCloud / non-local placeholder items so navigation never blocks on a
        // not-yet-downloaded file (these would also blow the latency budget — design D9 / non-goals).
        if values?.isUbiquitousItem == true { return nil }

        let isDirectory = values?.isDirectory ?? false
        let name = values?.name ?? url.lastPathComponent
        let modificationDate = values?.contentModificationDate
        let kind = fileKind(isDirectory: isDirectory, contentType: values?.contentType)
        return FileEntry(url: url, name: name, isDirectory: isDirectory,
                         modificationDate: modificationDate, kind: kind)
    }

    /// The folder's display name for an error headline — the localized filesystem name when available,
    /// else the last path component. Never includes raw OS text (that rides on `details`).
    private static func displayName(of folder: URL) -> String {
        let localized = (try? folder.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
        let name = localized ?? folder.lastPathComponent
        return name.isEmpty ? folder.path : name
    }

    // MARK: - Kind classification (boundary: UTType → the AppKit-free FileKind)

    /// Map a directory flag + the entry's `UTType` to the coarse, AppKit-free `FileKind` the view uses to
    /// pick a row glyph (the concrete SF Symbol stays in the view layer). A directory is always `.folder`
    /// regardless of its UTI (e.g. a bundle), matching `FileEntry`'s contract. Classification is by UTI
    /// conformance so subtypes (e.g. a specific image format) fold into their family.
    static func fileKind(isDirectory: Bool, contentType: UTType?) -> FileKind {
        if isDirectory { return .folder }
        guard let type = contentType else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .sourceCode }
        if type.conforms(to: .application) { return .application }
        if type.conforms(to: .text) { return .text }
        return .other
    }
}

/// The configurable order a folder's entries are listed in (spec: "ordered by a configurable sort
/// order"). A pure, AppKit-free value so it travels with the Files domain and is unit-testable; the Hub's
/// behavior page and `AppSettings` persist the user's choice and hand it to the lister.
///
/// Every order is **folders-first** (a Finder-mimic convention) and breaks ties with a localized,
/// case-insensitive name compare so the result is deterministic — a re-list of an unchanged folder yields
/// an identical ordering, which (with the path-stable `FileEntry.id`) is what keeps the highlight from
/// jumping.
enum FilesSortOrder: String, Equatable, CaseIterable, Codable, Sendable {
    /// A→Z by name (the default).
    case name
    /// Most-recently-modified first (entries without a date sort last).
    case dateModified
    /// File kind grouped, then by name.
    case kind

    /// The default order applied when the user has expressed no preference.
    static let `default`: FilesSortOrder = .name

    /// Sort `entries` by this order, folders-first, with a stable name tiebreak. Pure and total.
    func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            // Folders always lead, regardless of the chosen order (Finder-mimic).
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch self {
            case .name:
                break
            case .dateModified:
                let l = lhs.modificationDate, r = rhs.modificationDate
                if l != r {
                    // Newer first; a missing date sorts after any real date.
                    switch (l, r) {
                    case let (l?, r?): return l > r
                    case (_?, nil):    return true
                    case (nil, _?):    return false
                    case (nil, nil):   break
                    }
                }
            case .kind:
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            }
            // Tiebreak (and the whole comparison for `.name`): localized, case-insensitive name, then the
            // stable path id so equal names never compare equal (keeps the order total / deterministic).
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
