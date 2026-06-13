import Foundation

/// Failures the built-in player can report (`media-player` spec: "Player failures are observable,
/// bounded, and non-blocking").
///
/// This is the player-domain parallel to `FileActionError` (and the AI feature's `RuntimeError`): a small
/// Core taxonomy conforming to `LocalizedError`, with a clean, per-case, user-facing string for every
/// case — so a failure surfaces as a bounded headline that reads the same everywhere. `FileActionError`
/// is deliberately NOT reused: its cases are filesystem-action concepts (`folderUnreadable`,
/// `noApplicationForFile`) with no meaning for a playback failure, and folding the two together would
/// muddy both taxonomies.
///
/// **Map at the boundary:** AVFoundation (`AVError`/`NSError`) and libmpv (error codes) are converted into
/// these cases inside the engine conformers, where they cross into app code, so Core stays free of
/// framework/OS error types. The raw error is **stringified into the opt-in `details` payload at that
/// boundary** — kept ONLY for an opt-in "Show details / Copy" disclosure and logs, NEVER used as the
/// headline (`errorDescription`). Carrying `details` as a `String?` keeps the enum `Equatable`.
public enum MediaPlayerError: Error, Equatable, Sendable {
    /// The engine could not load the file at all (e.g. the file was removed, or the engine failed to
    /// initialize). `name` is the file's display name; `details` is opt-in copyable text.
    case loadFailed(name: String, details: String?)
    /// The default engine cannot decode this container/codec — the trigger for the libmpv fallback
    /// offer. `name` is the file's display name; `details` is opt-in copyable text.
    case unsupportedByDefaultEngine(name: String, details: String?)
    /// Playback failed mid-decode (a stream error after a successful load). `name` is the display name;
    /// `details` is opt-in copyable text.
    case decodeFailed(name: String, details: String?)
    /// The requested engine is unavailable on this machine (e.g. libmpv's bundled library is missing or
    /// could not be loaded).
    case engineUnavailable(engine: PlaybackEngineKind)
}

/// Self-describing, user-facing messages for every case — clean per-case sentences, so the "clean path"
/// (reading `errorDescription`) never falls back to a reflected enum dump or raw framework text. Raw error
/// text appears only in `copyableDetails` (→ opt-in disclosure) and logs (spec: "No raw error text in
/// user-facing strings").
extension MediaPlayerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .loadFailed(name, _):
            return "Couldn't open “\(name)”. It may have been moved or removed."
        case let .unsupportedByDefaultEngine(name, _):
            return "“\(name)” isn't supported by the default player. Try opening it in libmpv."
        case let .decodeFailed(name, _):
            return "Playback of “\(name)” failed. The file may be damaged or use an unsupported codec."
        case let .engineUnavailable(engine):
            return "The \(engine.displayName) player isn't available on this Mac."
        }
    }

    /// The opt-in copyable detail (the raw error text captured at the engine boundary), for a "Show
    /// details / Copy" disclosure and logs only. `nil` when the headline already says everything.
    public var copyableDetails: String? {
        switch self {
        case let .loadFailed(_, details): return details
        case let .unsupportedByDefaultEngine(_, details): return details
        case let .decodeFailed(_, details): return details
        case .engineUnavailable: return nil
        }
    }
}
