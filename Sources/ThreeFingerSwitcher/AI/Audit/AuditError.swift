import Foundation

/// Audit-store persistence failures (`ai-background-autonomy`, design Decision 7) — a new taxonomy ONLY
/// for the cases `RuntimeError`/`TaskError`/`SkillError`/`MemoryError`/`ParkError` cannot carry: the
/// append-only audit log's durable-store IO. Each case has a clean, user-facing `errorDescription`; raw
/// OS/coding text stays in opt-in details / logs (never the headline). `AIError.message(for:)` (the
/// single translator) is extended to translate this.
///
/// `FileManager`/JSON-coding throws map into this AT the `DiskAuditLog` IO boundary; Core stays MLX-free.
/// Crucially, `AuditLog.record(_:)` NEVER throws this into the route loop — a persistence failure is
/// observed bounded on the Hub viewer; the in-memory ring is unaffected (auditing must not break the
/// agent).
enum AuditError: Error, Equatable, LocalizedError {
    /// The durable audit store directory could not be created / opened (permission, read-only volume).
    case storeUnavailable(detail: String)
    /// A record could not be appended / the log could not be read back (disk full, permission, corruption).
    case persistFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return "The audit log couldn't be opened on disk."
        case .persistFailed:
            return "The audit log couldn't be saved."
        }
    }

    /// The copyable raw detail kept OUT of the headline.
    var rawDetail: String? {
        switch self {
        case let .storeUnavailable(detail), let .persistFailed(detail):
            return detail
        }
    }
}
