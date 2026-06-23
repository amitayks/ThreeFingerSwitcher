import Foundation

/// Surfaces ~3–5 candidate tools per route turn — never the full registry (design D6). The shape
/// deliberately mirrors `DocIndex.retrieve(query:limit:)` (blueprint §3.4) so that when
/// `ai-skills-as-files`/`ai-agent-memory` land, a `DocIndex`-backed source ranks skill/memory tools
/// through the SAME retriever — no second ranking path.
protocol ToolCandidateSource: Sendable {
    func candidates(for context: RouteContext, limit: Int) -> [ToolDescriptor]
}

/// The v1 default: a cheap lexical match of the latest user turn against each descriptor's
/// `name`/`summary`/`keywords` (token overlap + keyword substring), top-`limit`, always including the
/// active skill's allowed tools, capped at `additiveCap` total.
struct KeywordToolCandidateSource: ToolCandidateSource {
    let all: [ToolDescriptor]
    let additiveCap: Int

    init(all: [ToolDescriptor], additiveCap: Int = 8) {
        self.all = all
        self.additiveCap = additiveCap
    }

    func candidates(for context: RouteContext, limit: Int) -> [ToolDescriptor] {
        let queryTokens = Set(Self.tokenize(context.latestUserText))
        let queryLower = context.latestUserText.lowercased()

        func score(_ d: ToolDescriptor) -> Int {
            let hay = Set(Self.tokenize(d.name) + Self.tokenize(d.summary) + d.keywords.flatMap(Self.tokenize))
            let overlap = queryTokens.intersection(hay).count
            let substringBoost = d.keywords.contains { !$0.isEmpty && queryLower.contains($0.lowercased()) } ? 1 : 0
            return overlap + substringBoost
        }

        let allowed = all.filter { context.allowedTools.contains($0.name) }
        let ranked = all
            .filter { !context.allowedTools.contains($0.name) }
            .map { ($0, score($0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(max(0, limit))
            .map { $0.0 }

        // Ranked first (so the best match leads), allowed tools merged, deduped, capped.
        var seen = Set<String>()
        var out: [ToolDescriptor] = []
        for d in ranked + allowed where !seen.contains(d.name) {
            seen.insert(d.name)
            out.append(d)
            if out.count >= additiveCap { break }
        }
        return out
    }

    static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
}

extension ToolDescriptor {
    /// The retrieval-as-a-routed-step tool (blueprint §3.4 / Decision 6): the model calls this to ask for
    /// a broader candidate set when none of the current candidates fit. The loop widens the next turn's
    /// candidates in response. Read-only (`.auto`) — it changes nothing in the world.
    static let widenCandidates = ToolDescriptor(
        name: "widen_candidates",
        summary: "Request a broader set of tools when none of the offered candidates fit the request.",
        argsSchema: StructuredSchema(name: "widen_candidates", json: "{\"type\":\"object\"}"),
        writePolicy: .auto,
        keywords: ["other", "more", "different", "another", "tool"])
}
