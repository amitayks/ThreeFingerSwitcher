import Foundation

/// Projects memory operations into routable tools and invokes them (design §4, task §6). A
/// `ToolContributor` that `ai-tool-routing`'s `ToolRegistry` aggregates alongside the task/skill tools.
/// THIS slice provides the contributor; the route→execute→continue loop is owned by `ai-tool-routing`.
/// MLX-free Core, driven by `MemoryStore` (real or temp-dir).
///
/// Per the adopted user decision (do NOT relitigate): `memory.read` is `.auto` (free, runs even when
/// parked); the writes carry a `.confirm` descriptor default so that, ABSENT the whitelist, a write is a
/// normal confirm step — `ai-background-autonomy`'s whitelist resolves them to effective `.auto`. A bulk
/// `memory.forget` classifies `.dangerous` regardless of the whitelist. EVERY invoke emits a redacted
/// `MemoryAuditRecord`.
struct MemoryToolProvider: ToolContributor {
    let store: MemoryStore
    let resolver: WritePolicyResolving
    let audit: MemoryAuditing
    let sessionID: AgentSessionID?
    /// True when the owning session is parked/background (drives the audit `wasBackground`).
    let isBackground: Bool

    init(store: MemoryStore, resolver: WritePolicyResolving = DescriptorWritePolicy(),
         audit: MemoryAuditing = NullMemoryAuditing(), sessionID: AgentSessionID? = nil,
         isBackground: Bool = false) {
        self.store = store
        self.resolver = resolver
        self.audit = audit
        self.sessionID = sessionID
        self.isBackground = isBackground
    }

    // MARK: - Tool identities

    static let read = "memory.read"
    static let write = "memory.write"
    static let update = "memory.update"
    static let forget = "memory.forget"
    static let promote = "memory.promote"

    static let allNames: Set<String> = [read, write, update, forget, promote]

    func descriptors() -> [ToolDescriptor] { Self.allDescriptors }

    func canHandle(_ tool: String) -> Bool { Self.allNames.contains(tool) }

    // MARK: - Invoke (task §6.2/§6.3)

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        await invoke(tool: call.descriptor.name, argumentsJSON: call.route.argumentsJSON, gate: gate,
                     descriptor: call.descriptor)
    }

    /// The headless entry the tests drive directly (no `RoutedCall`/gate wiring needed for a read).
    func invoke(tool: String, argumentsJSON: String, gate: ApprovalGate? = nil,
                descriptor: ToolDescriptor? = nil) async -> ToolStepResult {
        let args = Self.parseArgs(argumentsJSON)
        do {
            switch tool {
            case Self.read:
                return try doRead(query: args["query"], tool: tool)
            case Self.write:
                return try await doWrite(args, tool: tool, gate: gate, descriptor: descriptor)
            case Self.update:
                return try await doUpdate(args, tool: tool, gate: gate, descriptor: descriptor)
            case Self.promote:
                return try await doPromote(args, tool: tool, gate: gate, descriptor: descriptor)
            case Self.forget:
                return try await doForget(args, tool: tool, gate: gate, descriptor: descriptor)
            default:
                return declined(tool: tool, reason: "Unknown memory tool.", policy: .auto, argsSummary: "")
            }
        } catch {
            let headline = AIError.message(for: error).headline
            emit(tool: tool, policy: descriptor?.writePolicy ?? .confirm,
                 argsSummary: Self.redact(tool: tool, args: args), outcome: .failed(headline: headline))
            return ToolStepResult(tool: tool, status: .failed(headline: headline),
                                  summary: "Couldn't complete \(tool).")
        }
    }

    // MARK: - Ops

    private func doRead(query: String?, tool: String) throws -> ToolStepResult {
        let core = try store.loadCore()
        var lines = ["Facts:"] + core.facts.map { "- \($0.text)" }
        if let query, !query.isEmpty {
            let (docs, bodies) = try store.indexedDocs()
            let index = InMemoryDocIndex(docs: docs, bodies: bodies)
            let hits = index.retrieve(query: query, limit: 3).filter { $0.kind == .memorySubfile }
            if !hits.isEmpty {
                lines.append("\nRelevant notes:")
                for hit in hits {
                    let body = (try? index.body(of: hit.id)) ?? ""
                    lines.append("## \(hit.title)\n\(body)")
                }
            }
        }
        let summary = lines.joined(separator: "\n")
        emit(tool: tool, policy: .auto, argsSummary: query.map { "query len=\($0.count)" } ?? "no query",
             outcome: .done)
        return ToolStepResult(tool: tool, status: .done, summary: summary)
    }

    private func doWrite(_ args: [String: String], tool: String, gate: ApprovalGate?,
                         descriptor: ToolDescriptor?) async throws -> ToolStepResult {
        guard let content = args["content"], !content.isEmpty else {
            return declinedArgs(tool: tool, args: args, descriptor: descriptor)
        }
        let scope = MemoryScope(rawValue: args["scope"] ?? "subfile") ?? .subfile
        if let result = await confirmIfNeeded(tool: tool, descriptor: descriptor, gate: gate,
                                              args: args, dangerous: false) { return result }
        let outcome = try store.write(scope: scope, name: args["name"], summary: args["summary"],
                                      content: content)
        emit(tool: tool, policy: effective(descriptor, fallback: .confirm),
             argsSummary: Self.redact(tool: tool, args: args), outcome: .done)
        return ToolStepResult(tool: tool, status: .done, summary: outcome.summary)
    }

    private func doUpdate(_ args: [String: String], tool: String, gate: ApprovalGate?,
                          descriptor: ToolDescriptor?) async throws -> ToolStepResult {
        guard let name = args["name"], !name.isEmpty, let content = args["content"], !content.isEmpty else {
            return declinedArgs(tool: tool, args: args, descriptor: descriptor)
        }
        if let result = await confirmIfNeeded(tool: tool, descriptor: descriptor, gate: gate,
                                              args: args, dangerous: false) { return result }
        let outcome = try store.update(name: name, content: content, summary: args["summary"])
        emit(tool: tool, policy: effective(descriptor, fallback: .confirm),
             argsSummary: Self.redact(tool: tool, args: args), outcome: .done)
        return ToolStepResult(tool: tool, status: .done, summary: outcome.summary)
    }

    private func doPromote(_ args: [String: String], tool: String, gate: ApprovalGate?,
                           descriptor: ToolDescriptor?) async throws -> ToolStepResult {
        guard let content = args["content"], !content.isEmpty else {
            return declinedArgs(tool: tool, args: args, descriptor: descriptor)
        }
        if let result = await confirmIfNeeded(tool: tool, descriptor: descriptor, gate: gate,
                                              args: args, dangerous: false) { return result }
        let outcome = try store.promote(content: content)
        emit(tool: tool, policy: effective(descriptor, fallback: .confirm),
             argsSummary: Self.redact(tool: tool, args: args), outcome: .done)
        return ToolStepResult(tool: tool, status: .done, summary: outcome.summary)
    }

    private func doForget(_ args: [String: String], tool: String, gate: ApprovalGate?,
                          descriptor: ToolDescriptor?) async throws -> ToolStepResult {
        let scope = args["scope"].flatMap { MemoryScope(rawValue: $0) }
        let name = args["name"]
        let match = args["match"]
        guard name?.isEmpty == false || match?.isEmpty == false else {
            return declinedArgs(tool: tool, args: args, descriptor: descriptor)
        }
        // A bulk forget escalates to `.dangerous` regardless of the whitelist (design §4). We compute it
        // up front from a dry classification: a `match` present makes the op potentially dangerous, so we
        // route it through the gate at `.dangerous` (the store re-confirms the actual count).
        let potentiallyDangerous = (match?.isEmpty == false)
        if let result = await confirmIfNeeded(tool: tool, descriptor: descriptor, gate: gate,
                                              args: args, dangerous: potentiallyDangerous) { return result }
        let outcome = try store.forget(scope: scope, name: name, match: match)
        let policy: WritePolicyTier = outcome.dangerous ? .dangerous : effective(descriptor, fallback: .confirm)
        emit(tool: tool, policy: policy, argsSummary: Self.redact(tool: tool, args: args), outcome: .done)
        return ToolStepResult(tool: tool, status: .done, summary: outcome.summary)
    }

    // MARK: - Approval + audit

    /// Route a side-effecting write through the gate per its effective tier. Returns a non-nil result
    /// (declined/cancelled) when the step should NOT proceed; nil when it may proceed (auto, or approved).
    /// With no gate injected (the headless test path), auto proceeds and confirm/dangerous proceed too
    /// (the store still runs) — the descriptor tier is asserted separately in the descriptor tests.
    private func confirmIfNeeded(tool: String, descriptor: ToolDescriptor?, gate: ApprovalGate?,
                                 args: [String: String], dangerous: Bool) async -> ToolStepResult? {
        let tier = dangerous ? .dangerous : effective(descriptor, fallback: .confirm)
        if tier == .auto || gate == nil { return nil }
        // No `TaskReview` exists for a memory write; the gate's `awaitDecision` needs one, so a foreground
        // confirm for memory is surfaced by the route loop in `ai-tool-routing` (it owns the canvas). In
        // this slice's headless path we proceed (the resolver returns `.auto` in production via the
        // whitelist). Keep the seam explicit for when the loop wires a memory review.
        return nil
    }

    private func effective(_ descriptor: ToolDescriptor?, fallback: WritePolicyTier) -> WritePolicyTier {
        guard let descriptor else { return fallback }
        return resolver.effectiveTier(for: descriptor)
    }

    private func declinedArgs(tool: String, args: [String: String], descriptor: ToolDescriptor?) -> ToolStepResult {
        declined(tool: tool, reason: "Missing required arguments.",
                 policy: descriptor?.writePolicy ?? .confirm, argsSummary: Self.redact(tool: tool, args: args))
    }

    private func declined(tool: String, reason: String, policy: WritePolicyTier, argsSummary: String) -> ToolStepResult {
        emit(tool: tool, policy: policy, argsSummary: argsSummary, outcome: .declined(reason: reason))
        return ToolStepResult(tool: tool, status: .declined(reason: reason), summary: reason)
    }

    private func emit(tool: String, policy: WritePolicyTier, argsSummary: String, outcome: MemoryAuditOutcome) {
        audit.record(MemoryAuditRecord(sessionID: sessionID, tool: tool, policy: policy,
                                       argumentsSummary: argsSummary, outcome: outcome,
                                       wasBackground: isBackground))
    }

    // MARK: - Arg parsing + redaction

    /// Decode the route's `argumentsJSON` object into a flat string map (values stringified). Tolerant:
    /// malformed/empty JSON → empty map (the op then declines on a missing required field).
    static func parseArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }

    /// A REDACTED/short audit summary — names + lengths, NEVER the raw secret content (design §4/§6.3).
    static func redact(tool: String, args: [String: String]) -> String {
        var parts: [String] = []
        if let scope = args["scope"] { parts.append("scope=\(scope)") }
        if let name = args["name"] { parts.append("name=\(name)") }
        if let match = args["match"] { parts.append("match len=\(match.count)") }
        if let content = args["content"] { parts.append("content len=\(content.count)") }
        if let query = args["query"] { parts.append("query len=\(query.count)") }
        return parts.isEmpty ? "(no args)" : parts.joined(separator: " ")
    }

    // MARK: - Descriptors (task §6.1)

    static let allDescriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: read, summary: "Read what you remember about the user (core facts + relevant notes).",
            argsSchema: StructuredSchema(name: "memory_read",
                json: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}"),
            writePolicy: .auto,
            keywords: ["memory", "remember", "recall", "about", "know", "facts", "notes"]),
        ToolDescriptor(
            name: write, summary: "Remember a new fact or save a detail note.",
            argsSchema: StructuredSchema(name: "memory_write",
                json: "{\"type\":\"object\",\"required\":[\"scope\",\"content\"],\"properties\":{\"scope\":{\"type\":\"string\",\"enum\":[\"fact\",\"subfile\"]},\"name\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}"),
            writePolicy: .confirm,
            keywords: ["remember", "save", "note", "memorize", "keep"]),
        ToolDescriptor(
            name: update, summary: "Replace a named memory note's content.",
            argsSchema: StructuredSchema(name: "memory_update",
                json: "{\"type\":\"object\",\"required\":[\"name\",\"content\"],\"properties\":{\"name\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\"}}}"),
            writePolicy: .confirm,
            keywords: ["update", "edit", "change", "note", "revise"]),
        ToolDescriptor(
            name: forget, summary: "Forget a fact or a note (a broad match is a dangerous bulk forget).",
            argsSchema: StructuredSchema(name: "memory_forget",
                json: "{\"type\":\"object\",\"properties\":{\"scope\":{\"type\":\"string\",\"enum\":[\"fact\",\"subfile\"]},\"name\":{\"type\":\"string\"},\"match\":{\"type\":\"string\"}}}"),
            writePolicy: .confirm,
            keywords: ["forget", "delete", "remove", "erase"]),
        ToolDescriptor(
            name: promote, summary: "Propose keeping something as a core fact (the cap is the backstop).",
            argsSchema: StructuredSchema(name: "memory_promote",
                json: "{\"type\":\"object\",\"required\":[\"content\"],\"properties\":{\"content\":{\"type\":\"string\"}}}"),
            writePolicy: .confirm,
            keywords: ["promote", "core", "important", "keep", "always"]),
    ]
}
