import Foundation

/// The Files band's single seam onto the system workspace (open / Open-With / app association).
///
/// Mirrors the `LLMRuntime` seam idea: the open/Open-With logic depends ONLY on this protocol — never on
/// `NSWorkspace` directly — so it is unit-testable against a stub that records calls and simulates
/// failures. The protocol is **dependency-light** (Foundation only, no AppKit) so a test stub conforms
/// without importing AppKit; the real `SystemFileWorkspace` conformer wraps `NSWorkspace` and lives behind
/// `#if canImport(AppKit)`.
///
/// The open operations are `async throws`: a conformer maps any underlying workspace/OS failure into the
/// shared `FileActionError` taxonomy **at this boundary** (so callers only ever see `FileActionError`, never
/// a raw `NSError`), and a non-throwing return means the open actually launched (never a false success).
/// The two association queries are synchronous and non-throwing — they only read the system's app
/// associations and naturally yield an empty list / `nil` when nothing handles the file.
protocol FileWorkspace {
    /// Open `url` in its default application. Throws a `FileActionError` if the open did not launch.
    func open(_ url: URL) async throws

    /// Open `url` with the application at `applicationURL`. Throws a `FileActionError` on failure.
    func open(_ url: URL, withApplicationAt applicationURL: URL) async throws

    /// The applications capable of opening `url`, in the system's order (default app first). Empty when no
    /// installed application handles the file.
    func urlsForApplications(toOpen url: URL) -> [URL]

    /// The default application for `url`, or `nil` when the system has no association for it.
    func urlForApplication(toOpen url: URL) -> URL?
}

#if canImport(AppKit)
import AppKit

/// The production `FileWorkspace`, wrapping `NSWorkspace`. Uses the modern async `open(_:configuration:)`
/// / `open(_:withApplicationAt:configuration:)` (so a launch failure is an awaited `throw`, mapped to the
/// taxonomy here) and `urlsForApplications(toOpen:)` / `urlForApplication(toOpen:)` for the associations.
///
/// `configuration.activates = true` so the opened window comes to the front on the **current** Space — the
/// new window lands natively where the user is; the Files band deliberately does NOT route opens through
/// `SpaceWindowMover` (design D9).
struct SystemFileWorkspace: FileWorkspace {
    init() {}

    func open(_ url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: config)
        } catch {
            // Map at the boundary: a raw NSWorkspace error never escapes into feature/UI code. The raw
            // text is stringified into the opt-in `details` here (and is the only place it survives).
            throw FileActionError.openFailed(name: url.lastPathComponent,
                                             details: String(describing: error))
        }
    }

    func open(_ url: URL, withApplicationAt applicationURL: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: applicationURL,
                                                  configuration: config)
        } catch {
            throw FileActionError.openFailed(name: url.lastPathComponent,
                                             details: String(describing: error))
        }
    }

    func urlsForApplications(toOpen url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    func urlForApplication(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }
}
#endif

/// Failures the Files band's side effects (directory listing, open, Open-With) can report.
///
/// This is the Files-domain parallel to the AI feature's `RuntimeError`: a small Core taxonomy conforming
/// to `LocalizedError`, with a clean, per-case, user-facing string for every case — so a failure surfaces
/// as a bounded headline that reads the same everywhere. The AI `RuntimeError` deliberately is NOT reused:
/// its cases (`modelMissing`, `integrityFailed`, `unsupportedModality`…) are model-layer concepts with no
/// meaning for a filesystem action, and folding file failures into it would muddy both taxonomies.
///
/// **Map at the boundary:** `FileManager` errors (listing) and `NSWorkspace`/OS errors (open) are converted
/// into these cases where they cross into app code (`DirectoryLister`, `SystemFileWorkspace.open`), so Core
/// stays free of vendor/OS error types. The raw error is **stringified into the opt-in `details` payload at
/// that boundary** — it is kept ONLY for an opt-in "Show details / Copy" disclosure and logs, and is NEVER
/// used as the headline (`errorDescription`). Carrying `details` as a `String?` (rather than a raw `Error`)
/// keeps the enum `Equatable` exactly like `RuntimeError.modelLoadFailed(detail:)`.
enum FileActionError: Error, Equatable {
    /// A folder's contents could not be read (e.g. permission denied, or it was removed). `name` is the
    /// folder's display name; `details` is opt-in copyable text (the raw `FileManager`/OS error, off the
    /// headline) — surfaced only as a disclosure / in logs.
    case folderUnreadable(name: String, details: String?)
    /// Opening a file or folder did not launch (e.g. the item was removed, or the app failed to start).
    /// `name` is the item's display name; `details` is opt-in copyable text (the raw workspace/OS error).
    case openFailed(name: String, details: String?)
    /// No installed application can open this file, so there is nothing to open it with.
    case noApplicationForFile(name: String)
    /// A Paste-into copy could not complete (e.g. permission denied, the destination is read-only, or the
    /// source was removed). `name` is the destination folder's display name; `details` is opt-in copyable
    /// text (the raw `FileManager`/OS error). The band's single mutating op (`files-action-menu`).
    case pasteFailed(name: String, details: String?)
    /// A Delete (move-to-Trash) could not complete (e.g. permission denied, or the item was already removed).
    /// `name` is the entry's display name; `details` is opt-in copyable text (the raw `FileManager`/OS error).
    /// The band only ever **trashes** (recoverable) — there is no permanent-delete error because there is no
    /// permanent delete.
    case trashFailed(name: String, details: String?)
}

/// Self-describing, user-facing messages for every case — clean per-case sentences, so the "clean path"
/// (reading `errorDescription`) never falls back to a reflected enum dump or raw OS text. These are the
/// canonical headlines a surfacing translator returns; raw error text appears only in `copyableDetails`
/// (→ opt-in disclosure) and logs, never here (spec: "No raw error text in user-facing strings").
extension FileActionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .folderUnreadable(name, _):
            return "Couldn't read “\(name)”. You may not have permission, or it was moved."
        case let .openFailed(name, _):
            return "Couldn't open “\(name)”. It may have been moved or removed."
        case let .noApplicationForFile(name):
            return "No app on this Mac can open “\(name)”."
        case let .pasteFailed(name, _):
            return "Couldn't paste into “\(name)”. You may not have permission, or it was moved."
        case let .trashFailed(name, _):
            return "Couldn't move “\(name)” to the Trash. You may not have permission, or it was already removed."
        }
    }

    /// The opt-in copyable detail (the raw error text captured at the boundary), for a "Show details / Copy"
    /// disclosure and logs only. `nil` when the headline already says everything (e.g. no app for the file).
    var copyableDetails: String? {
        switch self {
        case let .folderUnreadable(_, details): return details
        case let .openFailed(_, details): return details
        case .noApplicationForFile: return nil
        case let .pasteFailed(_, details): return details
        case let .trashFailed(_, details): return details
        }
    }
}
