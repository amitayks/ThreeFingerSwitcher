import Foundation

// MARK: - Files action-menu model (pure, MLX-free Core)

/// One action offered by the Files-band **action menu** (`files-action-menu`) — summoned by the menu
/// excursion (default the `+1`-finger lift) over a highlighted file or folder. A pure catalog enum; the
/// concrete effect runs at the boundary (`AppCoordinator`), the row label/glyph in the view layer.
///
/// Deliberately distinct from `GestureBindings.FilesAction` (the drill's `{open, openWith, discard}`
/// *resolution* vocabulary): this is the **menu item** catalog, several of which a single drill excursion
/// (the menu trigger) opens.
enum FilesMenuAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Copy the entry's absolute path into the clipboard history + live pasteboard.
    case copyAsPath
    /// Copy the entry's file/folder object (the `fileURL`) to the pasteboard.
    case copy
    /// Mark the entry for a MOVE: writes its `fileURL` to the pasteboard and records the cut, so the next
    /// `pasteInto` (while the pasteboard is still this cut) MOVES it instead of copying (Finder ⌘X).
    case cut
    /// Paste the pasteboard's file(s) INTO the folder (for a file: its containing folder) — **dual-mode**:
    /// a MOVE when fulfilling a `cut`, else a COPY; keep-both on conflict either way (never overwrites).
    case pasteInto
    /// The app grid (Open-With generalized): capable apps (file) / folder-openers (folder).
    case openIn
    /// Expands to one row per enabled terminal — opens the folder as that terminal's working directory.
    case openInTerminals
    /// Opt-in. Expands to one row per enabled editor — opens the folder in that editor.
    case openInEditor
    /// Opt-in. Reveal the entry selected in a Finder window.
    case revealInFinder
    /// Opt-in. Pin the entry into the launcher as a favorite.
    case addToFavorites
    /// Opt-in. Copy just the entry's display name (last path component).
    case copyName
    /// Move the entry to the **Trash** (recoverable from Finder) — never a permanent delete.
    case delete

    public var id: String { rawValue }

    /// The actions that are **defaults** (shown unless the user customizes); the rest are opt-in extras the
    /// user may add. Used by the Hub editor to present "available to add" vs. "in the menu."
    static let defaultCatalog: [FilesMenuAction] = [.copyAsPath, .copy, .cut, .pasteInto, .openInTerminals, .openIn, .delete]
    static let extras: [FilesMenuAction] = [.openInEditor, .revealInFinder, .addToFavorites, .copyName]
}

/// An external tool (terminal or editor) that can open a folder as its working directory. Auto-detected at
/// the boundary (a bundle-id probe); the pure menu model only needs its identity + display name + role to
/// build rows. `enabled` reflects the user's curation (the allow-list in `tunable-settings`).
struct FilesTool: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case terminal, editor }
    let bundleID: String
    let name: String
    let role: Role
    var enabled: Bool

    var id: String { bundleID }

    init(bundleID: String, name: String, role: Role, enabled: Bool = true) {
        self.bundleID = bundleID
        self.name = name
        self.role = role
        self.enabled = enabled
    }
}

/// One concrete, rendered row of the action menu after expanding groups and applying visibility rules — the
/// view iterates these, the controller dispatches on the committed one. `tool` carries which catalog action
/// produced it (terminals vs. editors) so the boundary opens with the right role.
enum FilesMenuRow: Identifiable, Equatable {
    /// A plain action row (everything except the tool groups).
    case action(FilesMenuAction)
    /// A terminal/editor row produced by `openInTerminals` / `openInEditor`.
    case tool(FilesMenuAction, FilesTool)

    var id: String {
        switch self {
        case let .action(a):       return "action:\(a.rawValue)"
        case let .tool(a, tool):   return "tool:\(a.rawValue):\(tool.bundleID)"
        }
    }
}

/// The user-configurable Files action-menu contents, per entry type (`files-action-menu`,
/// `tunable-settings`). Pure value; persisted via `AppSettings`. Defaults are **exactly** the user's
/// specified menus; any deviation is a customization.
struct FilesActionMenu: Codable, Equatable, Sendable {
    /// Ordered catalog items shown for a highlighted **file**.
    var fileItems: [FilesMenuAction]
    /// Ordered catalog items shown for a highlighted **folder**.
    var folderItems: [FilesMenuAction]

    init(fileItems: [FilesMenuAction] = FilesActionMenu.defaultFileItems,
         folderItems: [FilesMenuAction] = FilesActionMenu.defaultFolderItems) {
        self.fileItems = fileItems
        self.folderItems = folderItems
    }

    /// File default: Copy as path · Copy · Cut · Paste · Open in ▸ · Delete (Delete last, set apart).
    static let defaultFileItems: [FilesMenuAction] = [.copyAsPath, .copy, .cut, .pasteInto, .openIn, .delete]
    /// Folder default: Copy as path · Copy · Cut · Paste · ‹terminals› · Open in ▸ · Delete.
    static let defaultFolderItems: [FilesMenuAction] = [.copyAsPath, .copy, .cut, .pasteInto, .openInTerminals, .openIn, .delete]
    /// Both menus at their specified defaults.
    static let `default` = FilesActionMenu()

    /// The configured catalog order for a given entry type.
    func items(forFolder: Bool) -> [FilesMenuAction] { forFolder ? folderItems : fileItems }

    /// Resolve the configured catalog into the concrete, ordered rows for `entry`, applying runtime context:
    /// whether the live pasteboard currently holds a file reference (gates `pasteInto`) and the enabled
    /// tools (the `openInTerminals` / `openInEditor` groups expand to one row per enabled tool, and vanish
    /// when there are none). Pure → unit-tested.
    func visibleRows(for entry: FileEntry,
                     pasteboardHasFile: Bool,
                     terminals: [FilesTool],
                     editors: [FilesTool]) -> [FilesMenuRow] {
        items(forFolder: entry.isDirectory).flatMap { action -> [FilesMenuRow] in
            switch action {
            case .pasteInto:
                return pasteboardHasFile ? [.action(.pasteInto)] : []
            case .openInTerminals:
                return terminals.filter(\.enabled).map { .tool(.openInTerminals, $0) }
            case .openInEditor:
                return editors.filter(\.enabled).map { .tool(.openInEditor, $0) }
            default:
                return [.action(action)]
            }
        }
    }
}

// MARK: - Paste-into name resolution (pure)

/// Pure **keep-both** name resolver for the action menu's Paste-into (`files-action-menu`). Given a desired
/// file name and the set of names already present in the destination folder, return a name that does not
/// collide — the original if free, else `"name copy"`, `"name copy 2"`, … (Finder's convention), preserving
/// the file extension. Its whole job is to pick a **fresh** name so the incoming copy keeps both and the
/// existing item is never overwritten.
enum FilesPasteName {
    static func uniqueName(for desired: String, existing: Set<String>) -> String {
        guard existing.contains(desired) else { return desired }

        let ns = desired as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        func compose(_ stem: String) -> String { ext.isEmpty ? stem : "\(stem).\(ext)" }

        // Finder's first duplicate is "<base> copy", then "<base> copy 2", "<base> copy 3", …
        let firstCopy = compose("\(base) copy")
        if !existing.contains(firstCopy) { return firstCopy }
        var n = 2
        while true {
            let candidate = compose("\(base) copy \(n)")
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }
}
