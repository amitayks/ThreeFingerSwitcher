import Foundation

/// The canonical tool-routing contracts (blueprint §3.3 / design D2). This slice (`ai-tool-routing`,
/// Wave 2) OWNS them — it took ownership from the Wave-1 `ToolPlaceholders.swift` (now deleted), adding
/// the `keywords` retrieval signal to `ToolDescriptor`. The five public types are referenced by the
/// Wave-1 `AgentMessage`/`LLMChatRequest`; the routing-internal types (`RoutedCall`/`RouteContext`)
/// reference internal task types and so stay internal. MLX-free Core (`swift test`-verified).
///
/// Integration fix C1: the bare `WritePolicyTier` enum lives HERE (with `ToolDescriptor`) so every
/// descriptor is self-describing without a DAG back-edge to `ai-background-autonomy` (which owns only
/// the user whitelist, effective-tier resolution, the audit log, and escalation — never the enum).

/// Write-policy tier for a tool — drives auto / confirm / escalate.
public enum WritePolicyTier: String, Codable, Equatable, Sendable {
    /// Whitelisted/safe: runs without confirmation, even when parked (still audited downstream).
    case auto
    /// Default: needs foreground approval (DOWN=approve / RIGHT=skip).
    case confirm
    /// Always escalates to the foreground via the needs-you badge, even if parked.
    case dangerous
}

/// A tool the model may call. Describes itself to the router: a stable id, a one-line summary, the
/// arguments schema, its write-policy tier, and cheap retrieval `keywords` (the candidate-source ranking
/// signal, Decision 6).
public struct ToolDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let summary: String
    public let argsSchema: StructuredSchema
    public let writePolicy: WritePolicyTier
    public var keywords: [String]

    public init(name: String, summary: String, argsSchema: StructuredSchema,
                writePolicy: WritePolicyTier, keywords: [String] = []) {
        self.name = name
        self.summary = summary
        self.argsSchema = argsSchema
        self.writePolicy = writePolicy
        self.keywords = keywords
    }
}

/// The model's routing decision for one step (produced via `runtime.structured(RouteSchema, as:
/// ToolRoute.self)`). `tool == ""` is a plain text answer (the first-class "just talk" case). Decoding
/// is tolerant: a model that omits `argumentsJSON`/`rationale` decodes cleanly (defaults), so a plain
/// answer never trips the repair loop.
public struct ToolRoute: Codable, Equatable, Sendable {
    /// Matches a `ToolDescriptor.name`, or "" for a plain text answer.
    public let tool: String
    /// JSON object string of arguments; "" when `tool == ""`.
    public let argumentsJSON: String
    /// One short sentence — why this choice; rides the `.thinking` channel + the audit log.
    public let rationale: String?

    /// True when the model chose to answer directly rather than call a tool.
    public var isPlainAnswer: Bool { tool.isEmpty }

    public init(tool: String, argumentsJSON: String = "", rationale: String? = nil) {
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.rationale = rationale
    }

    enum CodingKeys: String, CodingKey { case tool, argumentsJSON, rationale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        argumentsJSON = try c.decodeIfPresent(String.self, forKey: .argumentsJSON) ?? ""
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
    }
}

/// The outcome of executing one routed step. Its `summary` is fed back into the loop as a `.tool`
/// message and is what `ChatTemplate.flatten` renders for a `.tool` turn.
public struct ToolStepResult: Codable, Equatable, Sendable {
    public let tool: String
    public let status: ToolStepStatus
    public let summary: String

    public init(tool: String, status: ToolStepStatus, summary: String) {
        self.tool = tool
        self.status = status
        self.summary = summary
    }
}

/// The status of an executed tool step. `.failed` carries a CLEAN headline only
/// (`AIPresentedError.headline`); raw error text goes to logs, never here.
public enum ToolStepStatus: Codable, Equatable, Sendable {
    case done
    case awaitingApproval
    case declined(reason: String)
    case failed(headline: String)
}

// MARK: - Routing-internal value types (reference internal task types → internal)

/// One routed call ready to run: the chosen descriptor, the model's route, the latest user text (the
/// content the bridge folds into the dispatcher's resolved prompt), and the fire-time provenance.
struct RoutedCall: Sendable {
    var descriptor: ToolDescriptor
    var route: ToolRoute
    var userText: String
    var source: TaskSource
}

/// The context a route turn / candidate retrieval reads: the conversation tail plus the active skill's
/// allowed tools (always offered as candidates).
struct RouteContext: Sendable {
    var messages: [AgentMessage]
    var activeSkillID: String?
    var allowedTools: [String]

    init(messages: [AgentMessage], activeSkillID: String? = nil, allowedTools: [String] = []) {
        self.messages = messages
        self.activeSkillID = activeSkillID
        self.allowedTools = allowedTools
    }

    /// The latest user turn's committed text — the query the candidate source ranks against.
    var latestUserText: String { messages.last(where: { $0.role == .user })?.text ?? "" }
}
