import Foundation

/// One ground-truth fact line in the CORE document. Short — identity facts ("I work at Acme"), not
/// detail (detail lives in subfiles).
struct MemoryFact: Equatable, Sendable {
    var text: String
    init(_ text: String) { self.text = text }
}

/// One table-of-contents entry in the CORE document: a subfile's name + its one-line summary. Mirrors
/// the subfiles folder; kept honest by reconciliation (design §6).
struct MemoryTOCEntry: Equatable, Sendable {
    var name: String
    var summary: String
}

/// The hard cap on the always-read CORE tier (design §2). The cap is on the SERIALIZED core because core
/// is injected into every session's context — the cost is the always-read token budget, not disk. Both a
/// byte cap and a fact-count cap (whichever binds first) make the decision robust to a few very long
/// facts vs. many short ones.
struct MemoryCap: Equatable, Sendable {
    var maxBytes: Int
    var maxFacts: Int

    /// Tuned defaults: ~8 KB / 60 facts keeps the always-read tier tiny by construction.
    static let `default` = MemoryCap(maxBytes: 8 * 1024, maxFacts: 60)
}

/// The pure CORE model (design §2, MLX-free Core). A `## Facts` list + a `## Contents` (TOC) list, with
/// pure `parse`/`serialized` and the cap/eviction decision as pure functions — no `FileManager`, fully
/// `swift test`-able headless. The `MemoryStore` bridges IO and turns evicted facts into real subfiles.
struct MemoryDocument: Equatable, Sendable {
    var facts: [MemoryFact]
    var contents: [MemoryTOCEntry]

    init(facts: [MemoryFact] = [], contents: [MemoryTOCEntry] = []) {
        self.facts = facts
        self.contents = contents
    }

    static let factsHeading = "## Facts"
    static let contentsHeading = "## Contents"

    // MARK: - Parse / serialize

    /// Parse `core.md` text. Tolerant: a missing section is empty; a fact is a `- ` bullet under
    /// `## Facts`; a TOC entry is a `- name — summary` bullet under `## Contents`. An absent/empty
    /// document is a valid empty doc (never an error).
    static func parse(_ text: String) -> MemoryDocument {
        var facts: [MemoryFact] = []
        var contents: [MemoryTOCEntry] = []
        enum Section { case none, facts, contents }
        var section: Section = .none

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == factsHeading { section = .facts; continue }
            if line == contentsHeading { section = .contents; continue }
            if line.hasPrefix("## ") { section = .none; continue }   // an unrelated heading ends a section
            guard line.hasPrefix("- ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            switch section {
            case .facts:
                facts.append(MemoryFact(item))
            case .contents:
                if let entry = parseTOCLine(item) { contents.append(entry) }
            case .none:
                continue
            }
        }
        return MemoryDocument(facts: facts, contents: contents)
    }

    /// Serialize back to `core.md` text. `parse(serialized())` is a fixed point. Both sections are always
    /// emitted (an empty section is just its heading) so the round-trip is byte-stable.
    func serialized() -> String {
        var lines: [String] = [Self.factsHeading]
        for fact in facts { lines.append("- \(fact.text)") }
        lines.append("")
        lines.append(Self.contentsHeading)
        for entry in contents { lines.append("- \(entry.name) — \(entry.summary)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The CORE facts as plain text (for the `.memoryCore` IndexedDoc body the shared index serves).
    func factsBody() -> String {
        facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    private static func parseTOCLine(_ item: String) -> MemoryTOCEntry? {
        // `name — summary` (em-dash separator, mirroring the serialized form). Tolerate a plain ` - `
        // hyphen too. Name only (no separator) is allowed (empty summary).
        for sep in [" — ", " - "] {
            if let r = item.range(of: sep) {
                let name = String(item[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let summary = String(item[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return MemoryTOCEntry(name: name, summary: summary) }
            }
        }
        let name = item.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : MemoryTOCEntry(name: name, summary: "")
    }

    // MARK: - The cap, as a pure decision (design §2)

    /// True when adding `fact` would push the serialized core past either cap.
    func wouldExceedCap(addingFact fact: MemoryFact, cap: MemoryCap) -> Bool {
        var probe = self
        probe.facts.append(fact)
        return probe.exceeds(cap)
    }

    func exceeds(_ cap: MemoryCap) -> Bool {
        if facts.count > cap.maxFacts { return true }
        if serialized().utf8.count > cap.maxBytes { return true }
        return false
    }

    /// Evict the lowest-value facts to fit the cap. v1 policy: **oldest-among-longest** — repeatedly move
    /// out the longest fact, breaking ties toward the oldest (earliest index), favoring evicting bulky
    /// detail-bearing lines while keeping terse identity facts. Returns the residual document + the
    /// evicted facts (the store bundles them into a subfile + a TOC entry). Terminates: every step removes
    /// one fact, so it cannot loop forever (a single fact still over the byte cap is the caller's
    /// `.capExceeded` guard).
    func evicting(toFit cap: MemoryCap) -> (kept: MemoryDocument, evicted: [MemoryFact]) {
        var kept = self
        var evicted: [MemoryFact] = []
        while kept.exceeds(cap), !kept.facts.isEmpty {
            // Longest fact wins; tie → earliest index (oldest).
            var victim = 0
            for i in kept.facts.indices where kept.facts[i].text.utf8.count > kept.facts[victim].text.utf8.count {
                victim = i
            }
            evicted.append(kept.facts.remove(at: victim))
        }
        return (kept, evicted)
    }
}
