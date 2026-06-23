import Foundation

/// The parsed, in-memory form of a skill (design D2) — an `AICommand` SUPERSET. It REUSES `AICommand`
/// verbatim (no field re-flattening), so `requiredCapabilities`, `resolvedReasoning`,
/// `defaultConfirmBeforeRun`, and the `{lang}` plumbing all come for free and stay consistent with band
/// items. The skill `id` (a stable string) is the *skill* identity (and the `ToolDescriptor.name`); the
/// embedded `AICommand.id` (a UUID) is the per-instance identity when added to a band. MLX-free Core.
struct SkillManifest: Equatable, Sendable, Identifiable {
    let id: String                 // file's `id`, path-relative, stable; the ToolDescriptor.name
    var origin: SkillOrigin        // .builtIn / .user (drives read-only + shadowing)
    var title: String
    var summary: String            // router-facing when-to-use line; the TOC summary
    var keywords: [String]
    var category: String?          // built-in projection grouping (nil for user skills)
    var command: AICommand         // the reused value model (icon/tint/input/template/output/param/reasoning)
    var toolNames: [String]        // optional allow-list of extra tools this skill may invoke
    var claudeHandoff: ClaudeHandoffConfig?
    var updatedAt: Date

    init(id: String, origin: SkillOrigin, title: String, summary: String, keywords: [String] = [],
         category: String? = nil, command: AICommand, toolNames: [String] = [],
         claudeHandoff: ClaudeHandoffConfig? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.origin = origin
        self.title = title
        self.summary = summary
        self.keywords = keywords
        self.category = category
        self.command = command
        self.toolNames = toolNames
        self.claudeHandoff = claudeHandoff
        self.updatedAt = updatedAt
    }

    /// The `IndexedDoc` this skill contributes to the shared `DocIndex` (kind `.skill`; the body is the
    /// prompt template, served by the store).
    func indexedDoc(bodyPath: URL) -> IndexedDoc {
        IndexedDoc(id: id, title: title, summary: summary, keywords: keywords,
                   kind: .skill, bodyPath: bodyPath, updatedAt: updatedAt)
    }
}

enum SkillOrigin: String, Codable, Sendable { case builtIn, user }
