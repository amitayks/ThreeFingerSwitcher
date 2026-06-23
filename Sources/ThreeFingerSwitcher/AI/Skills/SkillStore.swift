import Foundation

/// One bounded, non-blocking load problem (a malformed/duplicate skill file) — surfaced as a Hub row,
/// never an `NSAlert`, raw text only in logs/details.
struct SkillProblem: Equatable, Sendable {
    var fileName: String
    var headline: String
}

/// The result of loading the skill corpus: the valid skills + the problems (the load succeeds for the
/// rest even when some files are malformed).
struct SkillLoadResult: Sendable {
    var skills: [SkillManifest]
    var problems: [SkillProblem]
}

/// Loads the skill corpus and bridges async file IO to the pure `DocIndex` (design D5). Built-in skills
/// are PROJECTED from `AICommandCatalog` (the catalog stays the byte-for-byte source of truth for the
/// launcher/Bands editor — design deviation noted: lower-risk than inverting the heavily-tested catalog
/// to load from a bundle, same end state); user skills are read from a writable folder. A user skill
/// whose `id` matches a built-in SHADOWS it. The pure index never touches `FileManager`.
final class SkillStore: @unchecked Sendable {
    let userFolder: URL
    private var loaded: [SkillManifest] = []

    init(userFolder: URL) { self.userFolder = userFolder }

    /// The built-in skills — one per `AICommandCatalog` preset, projected in-memory (so the catalog and
    /// Bands editor are unchanged). The router-facing `summary` is derived from the command (the one
    /// field the in-code catalog never had); a user can author a better one by shadowing the skill.
    static func builtInManifests() -> [SkillManifest] {
        AICommandCatalog.entries.map { entry in
            let cmd = entry.command
            return SkillManifest(
                id: slug(cmd.name),
                origin: .builtIn,
                title: cmd.name,
                summary: derivedSummary(for: cmd),
                keywords: keywords(for: cmd),
                category: entry.category.rawValue,
                command: cmd)
        }
    }

    /// Load built-in ∪ user, shadow by id, validate. Built-in order preserved; user-only skills appended.
    func loadAll() async -> SkillLoadResult {
        let builtIn = Self.builtInManifests()
        let (userSkills, problems) = Self.loadUserFolder(userFolder)
        let userByID = Dictionary(userSkills.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let builtInIDs = Set(builtIn.map(\.id))
        var result = builtIn.map { userByID[$0.id] ?? $0 }                 // user shadows built-in in place
        result += userSkills.filter { !builtInIDs.contains($0.id) }        // user-only skills, after built-ins
        loaded = result
        return SkillLoadResult(skills: result, problems: problems)
    }

    /// The pure index over the last-loaded snapshot (the body of each skill is its prompt template).
    func index() -> DocIndex {
        let docs = loaded.map { $0.indexedDoc(bodyPath: bodyPath(for: $0)) }
        let bodies = Dictionary(loaded.map { ($0.id, $0.command.promptTemplate) }, uniquingKeysWith: { a, _ in a })
        return InMemoryDocIndex(docs: docs, bodies: bodies)
    }

    func manifest(id: String) -> SkillManifest? { loaded.first { $0.id == id } }

    private func bodyPath(for m: SkillManifest) -> URL {
        userFolder.appendingPathComponent("\(m.id).skill.md")
    }

    // MARK: - User folder

    static func loadUserFolder(_ folder: URL) -> ([SkillManifest], [SkillProblem]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return ([], [])   // empty / absent folder is not an error
        }
        let files = entries
            .filter { $0.lastPathComponent.hasSuffix(".skill.md") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // deterministic order (duplicate winner)

        var skills: [SkillManifest] = []
        var problems: [SkillProblem] = []
        var seen = Set<String>()
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                problems.append(problem(file, SkillError.unreadable(detail: file.path)))
                continue
            }
            switch SkillFile.parse(text, origin: .user) {
            case let .success(m):
                if seen.contains(m.id) {
                    problems.append(problem(file, SkillError.duplicateID(id: m.id)))
                } else {
                    seen.insert(m.id)
                    skills.append(m)
                }
            case let .failure(error):
                problems.append(problem(file, error))
            }
        }
        return (skills, problems)
    }

    private static func problem(_ file: URL, _ error: SkillError) -> SkillProblem {
        SkillProblem(fileName: file.lastPathComponent, headline: AIError.message(for: error).headline)
    }

    // MARK: - Projection helpers

    /// A path-relative, stable slug for a built-in skill id (e.g. "Fix Grammar" → "fix-grammar").
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A reasonable router-facing summary derived from the command (auto-seeded; a shadowing user file
    /// can author a better one).
    static func derivedSummary(for cmd: AICommand) -> String {
        let firstLine = cmd.promptTemplate
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? cmd.name
        let hint = firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        return "\(cmd.name) — \(hint)"
    }

    static func keywords(for cmd: AICommand) -> [String] {
        InMemoryDocIndex.tokenize(cmd.name)
    }
}
