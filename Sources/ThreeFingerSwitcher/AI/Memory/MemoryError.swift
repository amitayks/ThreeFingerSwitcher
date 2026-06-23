import Foundation

/// Agent-memory load/write failures (design §7) — a new taxonomy ONLY for the cases `RuntimeError`/
/// `TaskError`/`SkillError` cannot carry. Each case has a clean, user-facing `errorDescription`; raw
/// OS/parse text stays in opt-in details / logs (never the headline). `AIError.message(for:)` is
/// extended to translate this (the single translator). `FileManager`/parse throws map into this at the
/// `MemoryStore` IO boundary; Core stays MLX-free.
enum MemoryError: Error, Equatable, LocalizedError {
    /// The CORE document could not be read off disk (permission, corruption).
    case unreadableCore(detail: String)
    /// A memory write's disk IO did not land (disk full, permission, read-only volume).
    case writeFailed(detail: String)
    /// A named subfile the agent referenced does not exist.
    case subfileNotFound(name: String)
    /// A single fact larger than the entire core cap was forced into core (eviction cannot make room).
    case capExceeded
    /// A subfile on disk has malformed front-matter (excluded from the index, the rest still load).
    case malformedSubfile(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .unreadableCore:
            return "Your memory's core file could not be read."
        case .writeFailed:
            return "That memory couldn't be saved."
        case let .subfileNotFound(name):
            return "There's no memory note named “\(name)”."
        case .capExceeded:
            return "That's too long to keep as a core fact — save it as a note instead."
        case let .malformedSubfile(name, _):
            return "The memory note “\(name)” couldn't be read."
        }
    }
}
