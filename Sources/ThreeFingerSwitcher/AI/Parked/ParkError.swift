import Foundation

/// Parked-session store/persistence failures (design §9) — a new taxonomy ONLY for the cases
/// `RuntimeError`/`TaskError`/`SkillError`/`MemoryError` cannot carry: durable-store IO. Each case has a
/// clean, user-facing `errorDescription`; raw OS/coding text stays in opt-in details / logs (never the
/// headline). `AIError.message(for:)` is extended to translate this (the single translator).
/// `FileManager`/JSON-coding throws map into this AT the `ParkedSessionStore` IO boundary; Core stays
/// MLX-free.
enum ParkError: Error, Equatable, LocalizedError {
    /// The durable store directory could not be created / opened (permission, read-only volume).
    case storeUnavailable(detail: String)
    /// A parked session's conversation could not be written/read (disk full, permission, corruption).
    case persistFailed(detail: String)
    /// A sleeping session's one-line resume is missing when a restore needed it.
    case resumeMissing

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "Parked sessions couldn't be opened on disk."
        case .persistFailed:
            return "That parked session couldn't be saved."
        case .resumeMissing:
            return "That parked session couldn't be resumed."
        }
    }

    /// The copyable raw detail kept OUT of the headline (nil when the headline says everything).
    var rawDetail: String? {
        switch self {
        case let .storeUnavailable(detail), let .persistFailed(detail):
            return detail
        case .resumeMissing:
            return nil
        }
    }
}
