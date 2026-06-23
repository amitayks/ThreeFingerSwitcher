import Foundation

/// The shared retrieval contract (blueprint §3.4). OWNED by `ai-skills-as-files`; CONSUMED verbatim by
/// `ai-agent-memory` (integration fix C2 — memory contributes `IndexedDoc`s into the SAME index and
/// defines NO second retriever). Progressive disclosure: the TOC (`allSummaries`) is always cheap to show
/// the router; a doc's full body is loaded only on demand via `body(of:)`. MLX-free Core.

/// One retrievable unit — a skill file, a memory subfile, or a memory TOC entry.
struct IndexedDoc: Codable, Equatable, Identifiable, Sendable {
    let id: String                 // stable, path-relative id (also a skill's ToolDescriptor.name)
    var title: String
    var summary: String            // the TOC line the retriever ranks/returns first
    var keywords: [String]
    var kind: DocKind
    var bodyPath: URL              // where the full body lives (informational; body served by the store)
    var updatedAt: Date

    init(id: String, title: String, summary: String, keywords: [String], kind: DocKind,
         bodyPath: URL, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.summary = summary
        self.keywords = keywords
        self.kind = kind
        self.bodyPath = bodyPath
        self.updatedAt = updatedAt
    }
}

enum DocKind: String, Codable, Sendable { case skill, memoryCore, memorySubfile }

/// The shared retriever seam. Pure + synchronous over an in-memory snapshot; the owning store bridges
/// async file IO (the Files-band sync-model + async-cache pattern).
protocol DocIndex: Sendable {
    func allSummaries() -> [IndexedDoc]                        // the combined TOC the model always sees
    func retrieve(query: String, limit: Int) -> [IndexedDoc]   // ranked summaries for on-demand expansion
    func body(of id: String) throws -> String                  // load a doc's full body when the model asks
}

/// The pure, synchronous index over an injected `[IndexedDoc]` snapshot + a bodies map (id → full text)
/// the store populates off-main. Ranking never touches `FileManager`, so it is fully unit-testable. The
/// index is `kind`-agnostic — a combined skills + memory TOC is one `allSummaries()` over a merged
/// snapshot (blueprint C2).
struct InMemoryDocIndex: DocIndex {
    private let docs: [IndexedDoc]
    private let bodies: [String: String]

    init(docs: [IndexedDoc], bodies: [String: String]) {
        self.docs = docs
        self.bodies = bodies
    }

    func allSummaries() -> [IndexedDoc] { docs }

    /// Deterministic cheap ranking: token overlap + substring over title+summary+keywords, descending,
    /// stable tiebreak by id. A no-hit query returns [] (the router falls back to `allSummaries`).
    func retrieve(query: String, limit: Int) -> [IndexedDoc] {
        let q = Set(Self.tokenize(query))
        let qLower = query.lowercased()
        func score(_ d: IndexedDoc) -> Int {
            let hay = Set(Self.tokenize(d.title) + Self.tokenize(d.summary) + d.keywords.flatMap(Self.tokenize))
            let overlap = q.intersection(hay).count
            let sub = d.keywords.contains { !$0.isEmpty && qLower.contains($0.lowercased()) } ? 1 : 0
            return overlap + sub
        }
        return docs
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .prefix(max(0, limit))
            .map { $0.0 }
    }

    func body(of id: String) throws -> String {
        guard let body = bodies[id] else { throw SkillError.unreadable(detail: "No body for doc id \(id)") }
        return body
    }

    static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
}
