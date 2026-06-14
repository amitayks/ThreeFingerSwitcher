import Foundation

/// Bridges the Files band's **pure, synchronous** `FilesNavigationModel` to the **async, off-main**
/// `DirectoryLister` (design D6 / "the key seam"). The navigation model only learns a folder's contents
/// through a *synchronous* `(URL) -> [FileEntry]` closure, but the real listing crosses the `FileManager`
/// boundary asynchronously; this controller resolves that mismatch with a listing CACHE it owns:
///
/// - The synchronous lister handed to `FilesNavigationModel` reads `cache[folderPath] ?? []` — never the
///   filesystem. So the model stays pure and instantaneous; a not-yet-listed folder simply shows empty for
///   one beat.
/// - On a cache **miss** (the model descended / ascended into a folder we haven't listed) the controller
///   kicks off `DirectoryLister.contents(of:sortedBy:)` off-main. When it returns, the result is stored in
///   the cache, the model's *current* column is re-fed (`navigation.reloadCurrentColumn()`, which re-reads
///   through the same now-warm lister and preserves the highlight), and `onColumnChanged` fires so the
///   owner (`LauncherModel`) rebuilds the band's items and republishes — the view updates with the real
///   contents.
/// - The preview's folder-peek (`FilesNavigationModel.previewTarget`'s `.folder(_, contents:)`) flows
///   through the **same** cache, so a render never triggers a fresh `FileManager` read; an un-cached peek
///   warms the cache (and refreshes) exactly like a column miss.
///
/// `@MainActor` because it mutates the model the main-thread view reads and hops back onto the actor to
/// store listings; the only thing it does off the actor is the `DirectoryLister` read itself, which is
/// `nonisolated` and pure-Foundation.
@MainActor
final class FilesColumnController {

    // MARK: - Injected

    /// Lists a folder's local contents off-main, already sorted by the supplied order (the live
    /// `DirectoryLister`; a test injects a synchronous fixture wrapped to look async). The descending
    /// reversal is applied here, around the lister, so the cached column is in its final display order.
    private let lister: (URL, FilesSortOrder) async -> [FileEntry]

    /// The order to list folders in, recomputed from settings (`filesSortField`) each launcher open. A
    /// `var` so a settings change between opens is honoured on the next listing without rebuilding the
    /// controller. The ascending/descending *direction* rides separately in `sortDirection`.
    var sortOrder: FilesSortOrder

    /// Ascending vs. descending, applied (folders-first) on top of `sortOrder` after a listing returns —
    /// `FilesSortOrder` itself carries no direction (see `applyingDirection(_:to:)`).
    var sortDirection: FilesSortDirection

    /// Whether each (re)build of the navigation model opens displaying the remembered deepest folder rather
    /// than the roots list (the Hub "restore last folder" toggle; the owner passes
    /// `AppSettings.filesRememberLocation`). A stored property so `reset(roots:remembered:)` honours the same
    /// landing on a roots change. The deepest-location tracking is unaffected by this — it only governs the
    /// initial landing (see `FilesNavigationModel.init`).
    var restoreLastLocation: Bool

    /// Fired (on the main actor) whenever the current column's *visible contents* change — an async listing
    /// landed and was re-fed into the model. The owner rebuilds the Files band's `items` and republishes.
    var onColumnChanged: () -> Void = {}

    // MARK: - State

    /// The pure column-navigation state machine. Rebuilt by `reset(roots:remembered:)`; mutated in place by
    /// `descend()` / `ascend()` / `highlightUp()` / `highlightDown()`. Read-only to the owner via the
    /// forwarding accessors below so the cache-feeding invariants live solely here.
    private(set) var navigation: FilesNavigationModel

    /// The listing cache: standardized folder path → its listed entries (in final display order). The single
    /// source the synchronous lister (and the preview folder-peek) read from; populated only by completed
    /// async listings.
    private(set) var cache: [String: [FileEntry]] = [:]

    /// Folders an async listing is already in flight for (by standardized path), so a burst of misses for
    /// the same folder (a column feed + a preview peek in the same beat) coalesces to one read.
    private var inFlight: Set<String> = []

    /// The currently-spawned listing tasks, retained so callers (the initial-warm path, and tests) can
    /// `await settle()` until every in-flight listing has stored and re-fed. Drained as each task finishes.
    private var listingTasks: [Task<Void, Never>] = []

    // MARK: - Init

    /// Build the controller over `roots`, restoring `remembered` per-root locations. The navigation model is
    /// wired to a synchronous lister that reads *this* controller's cache, so the model never blocks; the
    /// landing column (and any restored remembered depth) is then warmed asynchronously.
    ///
    /// - Parameters:
    ///   - roots: the configured local root folders (the entry column).
    ///   - remembered: previously-persisted `root → deepest folder` map.
    ///   - sortOrder: the listing key, mapped from settings by the owner.
    ///   - sortDirection: ascending/descending, applied folders-first after listing.
    ///   - restoreLastLocation: open displaying the remembered deepest folder (the owner passes
    ///     `AppSettings.filesRememberLocation`) rather than the roots list. Threaded into the navigation model
    ///     so the band OPENS on that folder; the restored column (and its ancestors) is warmed below so the
    ///     first frame isn't empty.
    ///   - seededCache: folders already listed (standardized path → entries) to pre-warm the cache, so the
    ///     landing column (and tests over a fixed tree) is populated synchronously with no listing round-trip.
    ///   - lister: the async directory lister (defaults to the live `DirectoryLister`).
    init(roots: [URL],
         remembered: [URL: URL],
         sortOrder: FilesSortOrder,
         sortDirection: FilesSortDirection,
         restoreLastLocation: Bool = false,
         seededCache: [String: [FileEntry]] = [:],
         lister: @escaping (URL, FilesSortOrder) async -> [FileEntry] = FilesColumnController.systemLister) {
        self.lister = lister
        self.sortOrder = sortOrder
        self.sortDirection = sortDirection
        self.restoreLastLocation = restoreLastLocation
        self.cache = seededCache
        // `navigation` must be set before `self` is captured, so seed it with a roots-only model, then rebind
        // to the live cache (the rebind re-creates it with the same inputs but a `self`-capturing lister that
        // reads the now-seeded cache). Any folder not in `seededCache` lists empty until `warm…` fills it.
        self.navigation = FilesNavigationModel(roots: roots, remembered: remembered, lister: { _ in [] })
        rebindNavigationToLiveCache(roots: roots, remembered: remembered)
        warmCurrentColumnIfNeeded()
        warmAncestorColumns()
        warmPreviewTargetIfNeeded()
    }

    // MARK: - Forwarded read state (the owner builds the band from these)

    /// The current column's filtered entries — what the Files band's items are built from.
    var visibleEntries: [FileEntry] { navigation.visibleEntries }
    /// The highlighted row index into `visibleEntries` (drives the band's selected index).
    var highlightedIndex: Int { navigation.highlightedIndex }
    /// The highlighted entry, or nil on an empty column.
    var highlightedEntry: FileEntry? { navigation.highlightedEntry }
    /// The preview target for the current highlight (file-self vs folder-peek), or nil.
    var previewTarget: FilesNavigationModel.PreviewTarget? { navigation.previewTarget }
    /// Whether an ascend from here would leave the current column.
    var canAscend: Bool { navigation.canAscend }
    /// The per-root remembered locations to persist (the owner writes these back on depth change).
    var rememberedLocations: [URL: URL] { navigation.rememberedLocations }
    /// The current location (roots vs. a concrete folder) — lets the owner gate "did the depth change?".
    var current: FilesNavigationModel.Location { navigation.current }
    /// The ancestor folders above `current`, oldest first — drives any ancestor-rail / ancestor warming.
    var ancestors: [URL] { navigation.ancestors }
    /// The ordered breadcrumb path (root → … → highlighted item) for the bottom bar (refinement 4). Updates
    /// live as the highlight / folder changes.
    var breadcrumb: [FilesBreadcrumbComponent] { navigation.breadcrumb }

    // MARK: - Driving the column (the owner routes the recognizer here)

    /// Descend into the highlighted folder (horizontal, descend-direction). Warms the new column / preview
    /// if they aren't cached yet.
    func descend() {
        navigation.descend()
        warmCurrentColumnIfNeeded()
        warmPreviewTargetIfNeeded()
    }

    /// Ascend one level / back-out-to-roots (horizontal, the other direction). Warms as needed (the column
    /// we ascend to is usually already cached, but a cold restore may not be).
    func ascend() {
        navigation.ascend()
        warmCurrentColumnIfNeeded()
        warmPreviewTargetIfNeeded()
    }

    /// Move the highlight up one row (clamped at the top). Warms the new highlight's preview folder-peek if
    /// needed.
    func highlightUp() {
        navigation.highlightUp()
        warmPreviewTargetIfNeeded()
    }

    /// Move the highlight down one row. Warms the new highlight's preview folder-peek if needed.
    func highlightDown() {
        navigation.highlightDown()
        warmPreviewTargetIfNeeded()
    }

    // MARK: - Cache feeding (the async bridge)

    /// If the current column is a folder we haven't listed yet, kick off an async listing for it. A no-op
    /// at the roots list (the roots column is synthesized, not listed) and when the folder is already cached
    /// or in flight.
    private func warmCurrentColumnIfNeeded() {
        guard case let .folder(folder) = navigation.current else { return }
        fetchIfNeeded(folder)
    }

    /// Warm each restored ancestor folder's column (refinement 2: restore AT OPEN with no empty first
    /// frame). When the band opens deep — via the restore-last-location landing — the ancestor stack is
    /// already populated but their listings aren't cached; listing them now means an ascend (and any
    /// ancestor-rail peek) shows real contents immediately rather than empty-for-one-beat. Cheap and
    /// coalesced: `fetchIfNeeded` no-ops for anything already cached or in flight. A no-op when the stack is
    /// empty (the common shallow open).
    private func warmAncestorColumns() {
        for ancestor in navigation.ancestors {
            fetchIfNeeded(ancestor)
        }
    }

    /// If the highlighted entry is a folder whose contents aren't cached (the preview folder-peek would show
    /// empty), kick off a listing for it so the peek fills in. A no-op for a file highlight or an empty
    /// column.
    private func warmPreviewTargetIfNeeded() {
        guard let entry = navigation.highlightedEntry, entry.isDirectory else { return }
        fetchIfNeeded(entry.url)
    }

    /// List `folder` off-main unless it's already cached or a listing is in flight; on return store the
    /// result, re-feed the model's current column, and notify the owner. Coalesces duplicate requests.
    private func fetchIfNeeded(_ folder: URL) {
        let key = folder.standardizedFileURL.path
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let order = sortOrder
        let direction = sortDirection
        let task = Task { [weak self] in
            let listed = await self?.lister(folder, order) ?? []
            let ordered = Self.applyingDirection(direction, to: listed)
            self?.store(ordered, forFolderPath: key)
        }
        listingTasks.append(task)
    }

    /// Await every in-flight listing (and the cascade they trigger — a descend warms its new column, whose
    /// store re-feeds and may warm a newly-highlighted folder's preview) until the controller is quiescent.
    /// The live UI never needs to block on this (the view refreshes reactively via `onColumnChanged`); it
    /// exists so an initial-warm caller — and the unit tests — can drive the async bridge to completion
    /// deterministically without sleeping. Loops because completing one task can enqueue the next.
    func settle() async {
        while !listingTasks.isEmpty {
            let pending = listingTasks
            listingTasks = []
            for task in pending { await task.value }
        }
    }

    /// Store a completed listing into the cache, drop the in-flight mark, re-feed the model's current column
    /// (so a column whose miss triggered this listing now shows the real entries — and the highlight is
    /// preserved), and notify the owner to rebuild + republish when something visible changed. Runs on the
    /// main actor.
    private func store(_ entries: [FileEntry], forFolderPath key: String) {
        cache[key] = entries
        inFlight.remove(key)
        // Re-feed the current column unconditionally (cheap: re-reads through the warm cache). Notify only
        // when this listing actually changed a visible surface — the current column, or the folder-peek of
        // the *highlighted* folder — so an unrelated prefetch doesn't churn the view.
        let affectsCurrent = (navigation.current.folderURL?.standardizedFileURL.path == key)
        let highlighted = navigation.highlightedEntry
        let affectsPreview = (highlighted?.isDirectory == true)
            && (highlighted?.url.standardizedFileURL.path == key)
        navigation.reloadCurrentColumn()
        if affectsCurrent || affectsPreview { onColumnChanged() }
    }

    // MARK: - Reset (a fresh launcher open / a roots change)

    /// Rebuild the navigator over a new `roots`/`remembered` set (e.g. the user edited the roots, or a fresh
    /// launcher open with changed settings). Clears the cache and re-warms the landing column.
    func reset(roots: [URL], remembered: [URL: URL]) {
        cache = [:]
        inFlight = []
        rebindNavigationToLiveCache(roots: roots, remembered: remembered)
        warmCurrentColumnIfNeeded()
        warmAncestorColumns()
        warmPreviewTargetIfNeeded()
    }

    /// Build (or rebuild) `navigation` with a synchronous lister bound to *this controller's* live cache, so
    /// every read the model makes (column reload, ascend re-highlight, preview folder-peek) goes through the
    /// cache rather than the filesystem.
    private func rebindNavigationToLiveCache(roots: [URL], remembered: [URL: URL]) {
        navigation = FilesNavigationModel(roots: roots,
                                          remembered: remembered,
                                          restoreLastLocation: restoreLastLocation,
                                          lister: { [weak self] url in
                                              self?.cache[url.standardizedFileURL.path] ?? []
                                          })
    }

    // MARK: - Live system lister

    /// The default async lister: a fresh `DirectoryLister` read mapped to a non-throwing `[FileEntry]`. A
    /// read failure yields an empty column here — the typed `FileActionError` is still surfaced by the open
    /// path; a column *miss* degrades to empty rather than throwing through the pure model. The primary sort
    /// key is applied by the lister; the controller applies the direction (folders-first) on return.
    nonisolated static func systemLister(_ folder: URL, _ order: FilesSortOrder) async -> [FileEntry] {
        let lister = DirectoryLister()
        return (try? await lister.contents(of: folder, sortedBy: order)) ?? []
    }

    // MARK: - Sort mapping (settings → FilesSortOrder, folders-first descending)

    /// Map the persisted `FilesSortField` to the lister's `FilesSortOrder` (the primary key only — the
    /// ascending/descending direction is applied separately by `applyingDirection(_:to:)` because
    /// `FilesSortOrder` is directionless and always folders-first ascending).
    nonisolated static func sortOrder(field: FilesSortField) -> FilesSortOrder {
        switch field {
        case .name: return .name
        case .date: return .dateModified
        case .kind: return .kind
        }
    }

    /// Apply `direction` to an already-`FilesSortOrder`-sorted (ascending, folders-first) list, reversing
    /// **within the folders-first partition** for `.descending`.
    ///
    /// `FilesSortOrder` has no direction and always sorts ascending, folders-first. Reversing the *whole*
    /// array would put folders last (the leading folder run lands at the tail), breaking folders-first.
    /// Instead we partition into [folders] + [files] and reverse each partition independently, so folders
    /// stay on top but descending within their group (files likewise). `.ascending` returns the input
    /// unchanged. Pure — used by the live lister wrapper and exercised directly in tests.
    nonisolated static func applyingDirection(_ direction: FilesSortDirection, to entries: [FileEntry]) -> [FileEntry] {
        guard direction == .descending else { return entries }
        let folders = entries.filter { $0.isDirectory }
        let files = entries.filter { !$0.isDirectory }
        return Array(folders.reversed()) + Array(files.reversed())
    }
}
