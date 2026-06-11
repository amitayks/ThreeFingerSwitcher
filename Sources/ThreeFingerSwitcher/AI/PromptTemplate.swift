import Foundation

/// The captured context a command fires against (design D5): everything a prompt template can
/// reference, gathered at fire time from the front app and the acquired input. Pure value type so
/// templating is unit-testable without a running app.
struct FireContext: Equatable, Sendable {
    /// The name of the app that was frontmost when the launcher opened (`{app}`).
    var capturedAppName: String?
    /// The acquired input text (selection / clipboard / nothing). `{input}`.
    var inputText: String?
    /// The fire-time date/time (`{date}`).
    var date: Date
    /// The front document/page URL when the app exposes one (`{url}`); often nil.
    var url: URL?

    init(capturedAppName: String? = nil,
         inputText: String? = nil,
         date: Date = Date(),
         url: URL? = nil) {
        self.capturedAppName = capturedAppName
        self.inputText = inputText
        self.date = date
        self.url = url
    }
}

/// Resolves a command's prompt template against a `FireContext` (spec: "Prompt template token
/// resolution"). Supported tokens: `{input}`, `{date}`, `{app}`, `{url}`, `{lang}`.
///
/// Resolution rules (must never fail a command):
/// - Known tokens are replaced by their context value.
/// - A missing `{app}` / `{url}` (and an empty `{input}`) resolve to the EMPTY string, not an error.
/// - `{lang}` resolves to the command's ACTIVE runtime language; a command with no language parameter
///   passes `activeLanguage == nil` and so `{lang}` resolves to the EMPTY string (never fails).
/// - UNKNOWN tokens (e.g. `{foo}`) are left untouched verbatim, so a typo doesn't silently vanish.
enum PromptTemplate {

    /// The token names this resolver understands (everything else is passed through verbatim).
    static let knownTokens: Set<String> = ["input", "date", "app", "url", "lang"]

    /// Resolve `template` against `context`. `dateStyle`/`timeStyle` shape `{date}` (medium/short by
    /// default — human-readable, locale-aware). `activeLanguage` supplies `{lang}` (nil ⇒ empty).
    static func resolve(_ template: String,
                        with context: FireContext,
                        activeLanguage: String? = nil,
                        dateStyle: DateFormatter.Style = .medium,
                        timeStyle: DateFormatter.Style = .short) -> String {
        let values: [String: String] = [
            "input": context.inputText ?? "",
            "date": formattedDate(context.date, dateStyle: dateStyle, timeStyle: timeStyle),
            "app": context.capturedAppName ?? "",
            "url": context.url?.absoluteString ?? "",
            "lang": activeLanguage ?? ""
        ]
        return substitute(template, values: values)
    }

    /// Replace `{name}` occurrences for the names in `values`; leave any other `{...}` untouched.
    /// Single-pass scan so a substituted value can't itself be re-interpreted as a token.
    private static func substitute(_ template: String, values: [String: String]) -> String {
        var out = ""
        out.reserveCapacity(template.count)
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{", let close = template[i...].firstIndex(of: "}") {
                let nameStart = template.index(after: i)
                let name = String(template[nameStart..<close])
                if let value = values[name] {
                    out += value
                    i = template.index(after: close)
                    continue
                }
                // Unknown token: emit the brace literally and keep scanning from the next char so a
                // later valid token inside the same run is still resolved.
                out.append(ch)
                i = template.index(after: i)
            } else {
                out.append(ch)
                i = template.index(after: i)
            }
        }
        return out
    }

    private static func formattedDate(_ date: Date,
                                      dateStyle: DateFormatter.Style,
                                      timeStyle: DateFormatter.Style) -> String {
        let f = DateFormatter()
        f.dateStyle = dateStyle
        f.timeStyle = timeStyle
        return f.string(from: date)
    }
}
