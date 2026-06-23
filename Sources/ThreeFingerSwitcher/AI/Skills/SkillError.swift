import Foundation

/// Skill load/validation failures (design D6) — a new taxonomy ONLY for the cases `RuntimeError`/
/// `TaskError` cannot carry. Each case has a clean, user-facing `errorDescription`; raw OS/parse text
/// stays in opt-in details / logs (never the headline). `AIError.message(for:)` is extended to translate
/// this (the single translator). Skill *invocation* failures still flow through `RuntimeError`/`TaskError`.
enum SkillError: Error, Equatable, LocalizedError {
    case malformedFrontMatter(detail: String)
    case missingRequiredField(name: String)
    case unknownEnumValue(field: String, value: String)
    case duplicateID(id: String)
    case unreadable(detail: String)

    var errorDescription: String? {
        switch self {
        case .malformedFrontMatter:
            return "This skill file's front matter could not be read."
        case let .missingRequiredField(name):
            return "This skill file is missing a required field: \(name)."
        case let .unknownEnumValue(field, value):
            return "This skill file has an unrecognized \(field) value: “\(value)”."
        case let .duplicateID(id):
            return "Two skills share the same id “\(id)”; only the first was loaded."
        case .unreadable:
            return "This skill file could not be read."
        }
    }
}
