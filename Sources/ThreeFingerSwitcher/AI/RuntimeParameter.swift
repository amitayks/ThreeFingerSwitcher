import Foundation

/// A parameter chosen at FIRE TIME rather than baked into a command's prompt template (spec:
/// "Runtime-adjustable command parameter"). v1 ships exactly one parameter — a target language for
/// translate-style commands — surfaced as an in-canvas dropdown and persisted per command so the
/// next run defaults to the last choice. It is an enum so a future runtime parameter (tone, length,
/// format…) is additive without touching call sites that only care about `.language`.
enum RuntimeParameter: Codable, Equatable, Sendable {
    /// A choice from a declared option set whose value is substituted into the `{lang}` token.
    /// `default` is the cold-start value used until the user picks one (then per-command persistence
    /// overrides it); `options` is the dropdown's own list, so a translate command offers human
    /// languages while a "rewrite in language" command offers programming languages. Use the
    /// `.language(default:)` / `.codeLanguage(default:)` factories at call sites for the common cases.
    case languageChoice(default: String, options: [String])

    /// A human-language target parameter (the dropdown offers `AILanguages.all`).
    static func language(default def: String) -> RuntimeParameter {
        .languageChoice(default: def, options: AILanguages.all)
    }

    /// A programming-language target parameter (the dropdown offers `ProgrammingLanguages.all`).
    static func codeLanguage(default def: String) -> RuntimeParameter {
        .languageChoice(default: def, options: ProgrammingLanguages.all)
    }

    /// The declared default value, when this is a `.languageChoice` parameter (else nil).
    var languageDefault: String? {
        if case let .languageChoice(d, _) = self { return d }
        return nil
    }

    /// The declared option set the in-canvas dropdown should offer (else nil).
    var options: [String]? {
        if case let .languageChoice(_, o) = self { return o }
        return nil
    }
}

// MARK: - Backward-compatible Codable
//
// The case was renamed from the legacy `language(default:)` to `languageChoice(default:options:)`. A
// hand-rolled Codable keeps OLD persisted commands decodable (a band that stored `{"language": …}`
// before this change must still load — `AICommand` decodes its `runtimeParameter` with no migration
// pass) while always ENCODING the new shape. A legacy payload (no `options`) defaults to the human
// `AILanguages.all` list, matching the only commands that shipped a stored language (translate-style).
extension RuntimeParameter {
    private enum CodingKeys: String, CodingKey { case languageChoice, language }
    private enum PayloadKeys: String, CodingKey { case `default`, options }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .languageChoice) {
            let def = try nested.decode(String.self, forKey: .default)
            let options = try nested.decodeIfPresent([String].self, forKey: .options) ?? AILanguages.all
            self = .languageChoice(default: def, options: options)
        } else if let nested = try? container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .language) {
            // Legacy shape: only `default` was stored; default the options to the human-language list.
            let def = try nested.decode(String.self, forKey: .default)
            self = .languageChoice(default: def, options: AILanguages.all)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized RuntimeParameter payload"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .languageChoice(def, options):
            var nested = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .languageChoice)
            try nested.encode(def, forKey: .default)
            try nested.encode(options, forKey: .options)
        }
    }
}

/// The fixed list of languages the in-canvas dropdown offers (spec: "a fixed list of languages — no
/// free-form text entry, keyboardless"). The displayed name IS the value substituted into `{lang}`,
/// so the model sees a plain language name (e.g. "Hebrew").
enum AILanguages {
    /// Common languages, English first. Curated rather than exhaustive so the dropdown stays scrubbable.
    static let all: [String] = [
        "English", "Hebrew", "Spanish", "French", "German", "Italian", "Portuguese",
        "Dutch", "Arabic", "Russian", "Ukrainian", "Polish", "Turkish",
        "Chinese (Simplified)", "Japanese", "Korean", "Hindi"
    ]

    /// The dropdown options guaranteed to include `language` — so a persisted/declared default that
    /// isn't in the canonical list still appears and stays selectable (it is prepended if new).
    static func including(_ language: String) -> [String] {
        all.contains(language) ? all : [language] + all
    }
}

/// The fixed list of PROGRAMMING languages the dropdown offers for code-rewrite commands (e.g. "Rewrite
/// in Language"). The displayed name IS the value substituted into `{lang}`, so the model sees a plain
/// language name (e.g. "Rust").
enum ProgrammingLanguages {
    static let all: [String] = [
        "Python", "Swift", "JavaScript", "TypeScript", "Rust", "Go", "Java",
        "C", "C++", "C#", "Ruby", "Kotlin", "PHP", "SQL", "Shell"
    ]
}
