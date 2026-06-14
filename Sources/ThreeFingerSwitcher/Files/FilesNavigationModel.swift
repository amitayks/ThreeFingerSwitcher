import Foundation

/// One step of the Files band's bottom breadcrumb bar (refinement 4): a display `name` and the `url` it
/// points at, ordered root → … → currently-highlighted item. A value type so the view can diff the path
/// and the model can recompute it implicitly as the highlight / folder changes.
struct FilesBreadcrumbComponent: Equatable {
    /// The component's display name (a folder's or entry's last path component; a root's prettifiable name).
    let name: String
    /// The file URL this component refers to (standardized).
    let url: URL
}

/// The Files band's **pure** column-navigation state machine (design D6 / spec "Column navigation
/// model"). It owns the ancestors stack, the current folder, the highlighted entry, and the per-root
/// remembered locations — and **nothing else**: it never touches `FileManager`.
///
/// Determinism by injection: the only way it learns a folder's contents is the injected `lister`
/// closure (the live app wires that to `DirectoryLister`; a test wires a fixture). Because every input is
/// either a value handed in or that one closure, the whole machine is synchronous and exhaustively
/// unit-testable without a filesystem or a running app. The view layer reads `visibleEntries` /
/// `highlightedIndex` / `previewTarget` and renders; the recognizer drives `descend` / `ascend` /
/// `highlightUp` / `highlightDown`.
///
/// Mirrors how `LauncherModel`'s navigation is "pure, knows item counts + columns": this is the Files
/// analogue, just over a folder stack rather than a band grid.
struct FilesNavigationModel {

    // MARK: - Location

    /// Where the current column is rooted: the configured roots list (the entry column), or a concrete
    /// folder reached by descending. Backing out past a root returns to `.roots` (spec).
    enum Location: Equatable {
        /// The entry column: the configured root folders.
        case roots
        /// A concrete folder whose live contents fill the current column.
        case folder(URL)

        /// The folder URL when in a folder, else `nil` (the roots list has no single folder URL).
        var folderURL: URL? {
            if case let .folder(url) = self { return url }
            return nil
        }
    }

    // MARK: - Injected dependencies

    /// The configured local root folders, in order — shown as the initial current column. Standardized
    /// on init so a remembered-location prefix test (`hasPrefix`) lines up with listed entry ids.
    let roots: [URL]

    /// Lists a folder's entries on demand (the live app: `DirectoryLister`; a test: a fixture map). The
    /// model calls this exactly when the current folder changes (descend / ascend / restore), caching the
    /// result in `entries` until the next move — it never re-lists speculatively.
    private let lister: (URL) -> [FileEntry]

    // MARK: - State (current column)

    /// The ancestor folders above `current`, oldest first — i.e. the folders a left/ascend step pops back
    /// through. Empty when `current` is a root's top level or the roots list itself. Surfaced for the
    /// icon-rail (design D6).
    private(set) var ancestors: [URL] = []

    /// Where the current column is rooted.
    private(set) var current: Location = .roots

    /// The current column's entries (the roots as folder entries when at `.roots`, else the listed folder
    /// contents). The unfiltered backing list; the view shows `visibleEntries`.
    private(set) var entries: [FileEntry] = []

    /// The highlighted row's index into `visibleEntries`, clamped to it. `0` on an empty column.
    private(set) var highlightedIndex: Int = 0

    /// Per-root remembered **deepest** location: `root → last folder visited within it`. Injected in (the
    /// caller restores it from persistence) and surfaced out via `rememberedLocations` so the caller can
    /// persist it again — the model itself never persists. Keyed by standardized root URL.
    private var remembered: [URL: URL] = [:]

    /// Whether restoring the per-root remembered deepest location is enabled (the Hub "remember and reopen
    /// the last folder" toggle). When ON, the band both **opens** on the remembered folder (the `init`
    /// landing) AND, on a later descend into a root from the roots list, jumps straight to that root's
    /// remembered deepest location (`enterRoot`). When OFF, the band opens on the roots list and descending
    /// into a root lands on the root's **top level** — never the remembered folder. Tracking the deepest
    /// location continues regardless (so flipping the toggle back ON restores correctly); only *using* it to
    /// land is gated by this flag.
    private let restoreLastLocation: Bool

    // MARK: - Init

    /// Build the navigator over `roots`, restoring any previously-`remembered` per-root locations. `roots`
    /// and the remembered keys/values are standardized so path-prefix math and entry ids line up.
    ///
    /// Landing: when `restoreLastLocation` is true (the Hub "restore last folder" toggle, default ON) AND a
    /// `remembered` deepest location exists for a configured root, the model starts **at that folder** —
    /// `current = .folder(lastFolder)`, ancestors reconstructed and contents listed — so the band OPENS
    /// DISPLAYING the last folder (refinement 2: restore AT OPEN, not on the first descend). When false (or
    /// nothing is remembered) it lands on the roots list as before. The deepest-location *tracking* runs on
    /// every later move regardless; this flag only governs the initial landing.
    ///
    /// - Parameters:
    ///   - roots: the configured local root folders (the entry column).
    ///   - remembered: previously-persisted `root → deepest folder` map (default empty).
    ///   - restoreLastLocation: open displaying the remembered deepest folder (true) vs. the roots list
    ///     (false). Default false so callers that haven't opted in keep the roots-list landing.
    ///   - lister: lists a folder's entries on demand.
    init(roots: [URL],
         remembered: [URL: URL] = [:],
         restoreLastLocation: Bool = false,
         lister: @escaping (URL) -> [FileEntry]) {
        self.roots = roots.map { $0.standardizedFileURL }
        self.lister = lister
        self.restoreLastLocation = restoreLastLocation
        var standardizedRemembered: [URL: URL] = [:]
        for (root, location) in remembered {
            standardizedRemembered[root.standardizedFileURL] = location.standardizedFileURL
        }
        self.remembered = standardizedRemembered
        if restoreLastLocation, let landing = restorableLanding() {
            // Open straight onto the remembered folder: same ancestor reconstruction + listing as `enterRoot`,
            // but performed AT INIT so the displayed column matches where crossing horizontally will land.
            ancestors = intermediateFolders(from: landing.root, to: landing.folder)
            setCurrentFolder(landing.folder)
        } else {
            reloadCurrentColumn(resetHighlight: true)
        }
    }

    // MARK: - Derived view state

    /// The entries shown in the current column. Kept as a distinct accessor — the view, controller, and
    /// band builder all read the column through this name — though with type-to-filter search removed it
    /// now mirrors `entries` directly (the column is never filtered).
    var visibleEntries: [FileEntry] { entries }

    /// The highlighted entry within `visibleEntries`, or `nil` when the column is empty.
    var highlightedEntry: FileEntry? {
        let visible = visibleEntries
        guard visible.indices.contains(highlightedIndex) else { return nil }
        return visible[highlightedIndex]
    }

    /// The per-root remembered locations to persist (`root → deepest folder visited`). The caller writes
    /// this back to storage; the model never persists on its own.
    var rememberedLocations: [URL: URL] { remembered }

    /// Whether an ascend step from here would leave the current column (pop an ancestor, or step a root's
    /// top level back to the roots list). False only on the roots list itself, where ascend is a no-op.
    var canAscend: Bool { current != .roots }

    /// The ordered path the bottom breadcrumb bar shows (refinement 4): root → … → the currently-HIGHLIGHTED
    /// item. In a folder it is the ancestors, then the current folder, then the highlighted entry (when one
    /// is highlighted); at the roots list it is just the highlighted root (a root is the whole path). Recomputes
    /// implicitly as the highlight / folder changes — naming each URL by its last path component, the same
    /// AppKit-free convention `rootEntry(for:)` uses (the view can prettify).
    var breadcrumb: [FilesBreadcrumbComponent] {
        switch current {
        case .roots:
            // At the entry column the highlighted root IS the whole path; nothing above it.
            guard let root = highlightedEntry else { return [] }
            return [FilesBreadcrumbComponent(name: root.name, url: root.url)]
        case let .folder(folder):
            var components = ancestors.map { Self.breadcrumbComponent(for: $0) }
            components.append(Self.breadcrumbComponent(for: folder))
            // The highlighted entry is the leaf — but only when it isn't already the current folder (it never
            // is; the highlight is a child) and one exists (an empty/over-filtered column stops at the folder).
            if let highlighted = highlightedEntry {
                components.append(FilesBreadcrumbComponent(name: highlighted.name, url: highlighted.url))
            }
            return components
        }
    }

    // MARK: - Preview target

    /// What the highlighted entry previews (spec "preview-target derivation"): a **file** previews itself;
    /// a **folder** previews *its own contents* (the column descending would promote). `nil` when nothing
    /// is highlighted. The folder case carries the same listing the model would make current on descend,
    /// so the view's folder-contents peek and a subsequent descend agree.
    enum PreviewTarget: Equatable {
        /// Preview this file itself (QuickLook / icon fallback in the view).
        case file(FileEntry)
        /// Peek this folder's listed contents (what descending would make the current column).
        case folder(FileEntry, contents: [FileEntry])
    }

    /// The preview target for the current highlight, or `nil` when the column is empty.
    var previewTarget: PreviewTarget? {
        guard let entry = highlightedEntry else { return nil }
        if entry.isDirectory {
            return .folder(entry, contents: lister(entry.url))
        }
        return .file(entry)
    }

    // MARK: - Depth transitions (horizontal axis)

    /// Descend into the highlighted **folder**: push the prior current folder onto `ancestors` and make
    /// the highlighted folder current, listing its contents (spec). A no-op when nothing is highlighted or
    /// the highlight is a file (files open; they don't descend). Descending always resets the highlight to
    /// the top of the new column.
    ///
    /// From the **roots list**, descending into a root makes that root the current folder with an *empty*
    /// ancestor stack (a root is the base of its own column, not an ancestor) — and if that root has a
    /// remembered deeper location, restore straight to it (spec "re-entering that root restores it").
    mutating func descend() {
        guard let entry = highlightedEntry, entry.isDirectory else { return }
        let target = entry.url

        switch current {
        case .roots:
            // Entering a root: restore its remembered deepest location if we have one, else land on it.
            enterRoot(target)
        case let .folder(folder):
            ancestors.append(folder)
            setCurrentFolder(target)
        }
        rememberCurrentLocation()
    }

    /// Ascend one level (spec): pop the deepest ancestor back to current, or — at a root's top level (no
    /// ancestors) — return to the roots list. A no-op on the roots list itself. Resets the highlight and
    /// re-highlights the folder we came up from so the column doesn't feel lost.
    mutating func ascend() {
        switch current {
        case .roots:
            return                                   // already at the top; nothing to pop
        case let .folder(folder):
            if let parent = ancestors.popLast() {
                setCurrentFolder(parent, highlighting: folder)
            } else {
                returnToRoots(highlighting: folder)
            }
        }
        rememberCurrentLocation()
    }

    // MARK: - Highlight transitions (vertical axis)

    /// Move the highlight **down** one row (toward higher indices), clamped at the last visible row. A
    /// no-op (but harmless) on an empty column.
    mutating func highlightDown() {
        let count = visibleEntries.count
        guard count > 0 else { highlightedIndex = 0; return }
        highlightedIndex = min(highlightedIndex + 1, count - 1)
    }

    /// Move the highlight **up** one row (toward index 0), clamped at the top. An up-step while already at
    /// index 0 is a no-op — the highlight simply stays on the top row. (There is no type-to-filter search to
    /// overflow into; the navigator stays pure-trackpad.)
    mutating func highlightUp() {
        highlightedIndex = max(highlightedIndex - 1, 0)
    }

    // MARK: - Re-feed (async-listing bridge)

    /// Re-read the current column through the injected `lister` **without** moving — used when the column's
    /// contents change underneath a stationary navigator. The Files band lists folders asynchronously
    /// (off-main), but this model is synchronous and only re-reads on a move; when a late listing lands in
    /// the controller's cache (which backs the live `lister`), the controller calls this to pull the now-warm
    /// contents into the current column. The highlight is **preserved** (re-clamped, not reset) so a row the
    /// user is already on doesn't jump when its folder finishes loading; the location is untouched. A
    /// no-op-shaped read at `.roots` (the roots column is synthesized, not listed).
    mutating func reloadCurrentColumn() {
        reloadCurrentColumn(resetHighlight: false)
    }

    // MARK: - Private: column (re)loading

    /// Make `folder` the current column and list it, optionally re-highlighting a known child (used on
    /// ascend so the folder we came up from is selected).
    private mutating func setCurrentFolder(_ folder: URL, highlighting child: URL? = nil) {
        current = .folder(folder)
        reloadCurrentColumn(resetHighlight: child == nil)
        if let child { highlight(url: child) }
    }

    /// Return to the roots list (back-out-to-roots), optionally re-highlighting the root we came up from.
    /// Clears ancestors.
    private mutating func returnToRoots(highlighting child: URL? = nil) {
        ancestors = []
        current = .roots
        reloadCurrentColumn(resetHighlight: child == nil)
        if let child { highlight(url: child) }
    }

    /// The folder the band should OPEN displaying when restore-last-location is on, or `nil` to fall back to
    /// the roots list. `folder` is a remembered location that is still itself or a descendant of a configured
    /// root — i.e. a root the user has actually been into; `intermediateFolders(from:to:)` then rebuilds the
    /// ancestor chain for it (yielding `[]` when `folder == root`). Stale paths that no longer sit under their
    /// root (the root moved) are skipped, exactly like `enterRoot`.
    ///
    /// Choice when several roots are remembered: the persisted seam (`AppSettings.filesRememberedLocations`)
    /// is per-root with **no timestamp**, so a true global "last visited" isn't recoverable. We therefore pick
    /// the **deepest** valid remembered path — the most specific "where you left off" — breaking ties by
    /// configured-root order so the result is deterministic. (The common single-root setup has exactly one
    /// candidate, so this only matters across multiple deep roots.)
    private func restorableLanding() -> (root: URL, folder: URL)? {
        var best: (root: URL, folder: URL)?
        for root in roots {
            guard let deepest = remembered[root] else { continue }
            let candidate: URL
            if deepest == root {
                candidate = root                       // root top level (valid, depth = the root's own)
            } else if isDescendant(deepest, of: root) {
                candidate = deepest                    // a deeper remembered location under this root
            } else {
                continue                               // stale: outside the root → ignore
            }
            // Deepest path wins; configured-root order is the tie-break (strict `>` keeps the earlier root).
            if best == nil || candidate.standardizedFileURL.path.count > best!.folder.standardizedFileURL.path.count {
                best = (root, candidate)
            }
        }
        return best
    }

    /// Enter `root` from the roots list. When `restoreLastLocation` is ON, restore its remembered deepest
    /// location if one exists and is still a descendant of the root (spec "restore where you left off"),
    /// reconstructing the ancestor stack so ascending walks back up correctly; otherwise — and **always**
    /// when the toggle is OFF — land on the root's **top level**. Gating on `restoreLastLocation` here (not
    /// just at `init`) is what keeps the toggle honest: with it off, descending into a root must NOT jump to
    /// the last-visited folder (the deepest-location map is still tracked for when the toggle is turned on).
    private mutating func enterRoot(_ root: URL) {
        ancestors = []
        if restoreLastLocation,
           let deepest = remembered[root], deepest != root, isDescendant(deepest, of: root) {
            // Rebuild ancestors = [root, …intermediate folders…] up to (but excluding) `deepest`.
            ancestors = intermediateFolders(from: root, to: deepest)
            setCurrentFolder(deepest)
        } else {
            setCurrentFolder(root)
        }
    }

    /// List the current location into `entries`, optionally resetting the highlight to the top. At
    /// `.roots` the entries are the configured roots projected as folder `FileEntry`s (no `FileManager`
    /// read); in a folder they come from the injected `lister`.
    private mutating func reloadCurrentColumn(resetHighlight: Bool) {
        switch current {
        case .roots:
            entries = roots.map(Self.rootEntry(for:))
        case let .folder(folder):
            entries = lister(folder)
        }
        if resetHighlight { highlightedIndex = 0 }
        clampHighlight()
    }

    /// Re-clamp `highlightedIndex` into the current `visibleEntries` so it never points off the end (after
    /// a re-list, a search, or an ascend that re-highlights). Lands on `0` for an empty column.
    private mutating func clampHighlight() {
        let count = visibleEntries.count
        guard count > 0 else { highlightedIndex = 0; return }
        highlightedIndex = min(max(highlightedIndex, 0), count - 1)
    }

    /// Highlight the entry whose URL matches `url` within the current (unfiltered) column, if present —
    /// used to re-select the folder we just came up from on ascend. Falls back to leaving the clamp at 0.
    private mutating func highlight(url: URL) {
        let target = url.standardizedFileURL.path
        if let index = visibleEntries.firstIndex(where: { $0.id == target }) {
            highlightedIndex = index
        } else {
            clampHighlight()
        }
    }

    // MARK: - Private: remembered-location bookkeeping

    /// Record the current folder as the deepest-visited location for whichever root it lives under, so a
    /// later re-entry restores it (spec: "remember the **deepest** location"). A no-op at the roots list.
    /// The "deepest" contract is explicit: this runs on *every* move (descend AND ascend), so it must
    /// never let an ascend shrink the remembered depth — it overwrites only when the current folder is at
    /// least as deep as what's already remembered (i.e. the existing value isn't a strict descendant of
    /// `folder`). Descending deeper updates it; ascending back up keeps the deeper mark.
    private mutating func rememberCurrentLocation() {
        guard case let .folder(folder) = current, let root = owningRoot(of: folder) else { return }
        if let existing = remembered[root], isDescendant(existing, of: folder) { return }
        remembered[root] = folder
    }

    /// The configured root that `folder` lives under (itself or a descendant), or `nil` if none — the
    /// longest matching root wins so nested roots remember independently.
    private func owningRoot(of folder: URL) -> URL? {
        roots
            .filter { folder == $0 || isDescendant(folder, of: $0) }
            .max { $0.path.count < $1.path.count }
    }

    // MARK: - Private: path helpers (pure)

    /// A root projected as a folder `FileEntry` for the roots column. The display name is the root's
    /// last path component (the view can prettify; the model stays AppKit-free), `isDirectory == true`.
    private static func rootEntry(for root: URL) -> FileEntry {
        let name = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        return FileEntry(url: root, name: name, isDirectory: true, modificationDate: nil, kind: .folder)
    }

    /// A folder URL as a breadcrumb component — its last path component (falling back to the full path for a
    /// filesystem root), matching `rootEntry(for:)`'s naming so an ancestor reads the same in the rail and
    /// the breadcrumb. The view can prettify; the model stays AppKit-free.
    private static func breadcrumbComponent(for folder: URL) -> FilesBreadcrumbComponent {
        let name = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        return FilesBreadcrumbComponent(name: name, url: folder)
    }

    /// True when `url` is a strict descendant of `ancestor` (a deeper path under it). Path-prefix math on
    /// standardized paths, boundary-aware (so `/a/bc` is not treated as under `/a/b`).
    private func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let child = url.standardizedFileURL.path
        var base = ancestor.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        return child.hasPrefix(base) && child.count > base.count
    }

    /// The chain of folders to push as ancestors when restoring from `root` down to `deepest`: `[root,
    /// …each intermediate folder…]`, excluding `deepest` itself (which becomes current).
    ///
    /// Works in **path-space** and rebuilds each ancestor via `URL(fileURLWithPath:)` so the result uses
    /// the SAME no-trailing-slash convention as every other URL in the model (`FileEntry.url`, the roots,
    /// `current`). `deletingLastPathComponent()` would instead yield directory URLs *with* a trailing
    /// slash that fail `==` against those bare URLs — which `ascend`'s `popLast()` → `setCurrentFolder`
    /// comparison (and the tests) depend on. The caller guarantees `deepest` is a strict descendant of
    /// `root`, so the path-component prefix below always lines up.
    private func intermediateFolders(from root: URL, to deepest: URL) -> [URL] {
        let rootPath = root.standardizedFileURL.path
        let rootComponents = pathComponents(rootPath)
        let deepComponents = pathComponents(deepest.standardizedFileURL.path)
        guard deepComponents.count > rootComponents.count else { return [] }

        // Ancestors run from the root down to the folder just above `deepest` (its parent), inclusive of
        // the root, exclusive of `deepest`. e.g. root /Home, deepest /Home/Docs/Sub → [/Home, /Home/Docs].
        var chain: [URL] = []
        for end in rootComponents.count...(deepComponents.count - 1) {
            let path = "/" + deepComponents.prefix(end).joined(separator: "/")
            chain.append(URL(fileURLWithPath: path))
        }
        return chain
    }

    /// The non-empty path segments of an absolute POSIX path (`/Home/Docs` → `["Home", "Docs"]`; `/` →
    /// `[]`). Pure string splitting — used so ancestor URLs are rebuilt component-by-component.
    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
