import Foundation

/// Failures the Dock-preview commit (raise / un-minimize-then-raise) can report.
///
/// The Dock-domain parallel to the Files feature's `FileActionError`: a small Core taxonomy conforming to
/// `LocalizedError` with a clean, per-case, user-facing sentence for every case — so a failed commit
/// surfaces as a bounded headline that reads the same everywhere, never a reflected enum dump or raw OS
/// text. (The AI `RuntimeError` and `FileActionError` are deliberately NOT reused: their cases are
/// model-/filesystem-layer concepts with no meaning for a window-raise action.)
///
/// **Map at the boundary:** any underlying AX/OS failure is converted into one of these cases where it
/// crosses into feature/UI code, and the raw text is stringified into the opt-in `details` payload there —
/// kept ONLY for a "Show details / Copy" disclosure and logs, NEVER used as the headline. Carrying
/// `details` as a `String?` (not a raw `Error`) keeps the enum `Equatable`, like `FileActionError`.
enum DockPreviewError: Error, Equatable {
    /// The chosen window could no longer be found at commit time (closed, or moved off this Space).
    /// `name` is the window's display title.
    case windowUnavailable(name: String)
    /// Bringing the window forward did not succeed. `name` is the window's display title; `details` is
    /// opt-in copyable text (the raw AX/OS error), off the headline.
    case raiseFailed(name: String, details: String?)
}

extension DockPreviewError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .windowUnavailable(name):
            return "“\(name)” isn't available anymore. It may have been closed or moved to another Space."
        case let .raiseFailed(name, _):
            return "Couldn't bring “\(name)” to the front. Try clicking it again."
        }
    }

    /// The opt-in copyable detail (raw error captured at the boundary), for a "Show details / Copy"
    /// disclosure and logs only. `nil` when the headline already says everything.
    var copyableDetails: String? {
        switch self {
        case .windowUnavailable: return nil
        case let .raiseFailed(_, details): return details
        }
    }
}
