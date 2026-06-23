import Foundation

/// A named memory subfile (design §1/§2.1): front-matter (`name`/`summary`/`keywords`/`updatedAt`) + a
/// free-Markdown detail body, mirroring the `.skill.md` shape so a subfile and a skill index identically.
/// Pure value type; parse/serialize never touch `FileManager`. A malformed file maps at the parse
/// boundary into `MemoryError.malformedSubfile` (a bounded problem — excluded from the index, the rest
/// still load). MLX-free Core.
struct MemorySubfile: Equatable, Sendable {
    var name: String
    var summary: String
    var keywords: [String]
    var body: String
    var updatedAt: Date

    init(name: String, summary: String, keywords: [String] = [], body: String, updatedAt: Date = Date()) {
        self.name = name
        self.summary = summary
        self.keywords = keywords
        self.body = body
        self.updatedAt = updatedAt
    }

    /// The TOC entry this subfile contributes to `core.md`'s `## Contents` (design §6).
    var tocEntry: MemoryTOCEntry { MemoryTOCEntry(name: name, summary: summary) }

    /// The `IndexedDoc` this subfile contributes to the SHARED `DocIndex` (kind `.memorySubfile`; the
    /// body is the detail text, served by the store). Id namespaced under `memory/` so a subfile name can
    /// never collide with a skill id (different folder + kind — the documented contract).
    func indexedDoc(bodyPath: URL) -> IndexedDoc {
        IndexedDoc(id: MemorySubfile.docID(for: name), title: name, summary: summary,
                   keywords: keywords, kind: .memorySubfile, bodyPath: bodyPath, updatedAt: updatedAt)
    }

    /// The namespaced, path-relative id for a subfile (structurally distinct from any skill id).
    static func docID(for name: String) -> String { "memory/subfile/\(name)" }

    // MARK: - Parse / serialize (mirrors SkillFile)

    /// Parse a subfile document. Returns a typed `MemoryError.malformedSubfile` on any malformation
    /// (missing delimiters, missing `name`/`summary`). `fallbackName` (the on-disk filename stem) is used
    /// in the error so a problem is attributable even when the front-matter `name` is the thing missing.
    static func parse(_ text: String, fallbackName: String) -> Result<MemorySubfile, MemoryError> {
        guard let (frontMatter, body) = splitFrontMatter(text) else {
            return .failure(.malformedSubfile(name: fallbackName, detail: "Missing the `---` front-matter delimiters."))
        }
        let fields = parseFields(frontMatter)
        guard let name = fields["name"], !name.isEmpty else {
            return .failure(.malformedSubfile(name: fallbackName, detail: "Missing required field: name."))
        }
        guard let summary = fields["summary"], !summary.isEmpty else {
            return .failure(.malformedSubfile(name: name, detail: "Missing required field: summary."))
        }
        let keywords = parseList(fields["keywords"])
        let updatedAt = fields["updatedAt"].flatMap(parseDate) ?? Date(timeIntervalSince1970: 0)
        return .success(MemorySubfile(name: name, summary: summary, keywords: keywords,
                                      body: body, updatedAt: updatedAt))
    }

    /// Serialize back to subfile text. `parse(serialize(s))` is a fixed point.
    func serialized() -> String {
        var lines = ["---"]
        lines.append("name: \(name)")
        lines.append("summary: \(summary)")
        if !keywords.isEmpty { lines.append("keywords: [\(keywords.joined(separator: ", "))]") }
        lines.append("updatedAt: \(Self.isoString(updatedAt))")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + body
    }

    // MARK: - Helpers (mirror SkillFile's hand-rolled subset)

    private static func splitFrontMatter(_ text: String) -> (frontMatter: [String], body: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let firstDelim = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let rest = lines[(firstDelim + 1)...]
        guard let closeOffset = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let fm = Array(lines[(firstDelim + 1)..<closeOffset])
        let body = lines[(closeOffset + 1)...].joined(separator: "\n")
        return (fm, body.trimmingCharacters(in: .newlines))
    }

    private static func parseFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func parseList(_ value: String?) -> [String] {
        guard let value, value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        return value.dropFirst().dropLast()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    static func isoString(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.string(from: date)
    }
}
