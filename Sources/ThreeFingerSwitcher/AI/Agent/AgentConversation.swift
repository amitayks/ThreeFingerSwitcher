import Foundation

/// The canonical multi-turn conversation types (blueprint §3.1 / design D1). This slice
/// (`ai-conversation-runtime`, Wave 1) OWNS them; every other V2 slice — tool-routing, the
/// conversational canvas, parked sessions, memory, background autonomy, the batched runtime — imports
/// these shapes verbatim rather than inventing conflicting ones. MLX-free Core (`swift test`-verified).
///
/// THE LOAD-BEARING INVARIANT: a message's committed text (`text`) is the ONLY content ever re-fed into
/// the model's context on a later turn; its reasoning (`thinking`) is retained for DISPLAY only and is
/// NEVER re-fed as ground truth. Thinking lives in a separate field so the exclusion is *structural* —
/// the assembler (`ChatTemplate.flatten`) reads `text` only and never touches `thinking`. A bug that
/// re-fed reasoning would both bloat the context window and violate the contract; keeping the two fields
/// apart makes that bug impossible by construction rather than by a fragile strip step. The ordered
/// `segments` timeline (`notch-timeline-and-tuning`) sits in the same DISPLAY-only tier as `thinking`:
/// assembly never reads it.

/// One display-only block of an assistant turn's TIMELINE (`notch-timeline-and-tuning`): the turn's
/// thinking and answer in token-arrival order, a new segment starting wherever the channel flips — so the
/// transcript can re-render the interleaved thinking/answer sequence exactly as it streamed. Display-only
/// like `thinking` (never re-fed; assembly reads `text` only).
public struct TurnSegment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case thinking, answer
    }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The role of a message in a conversation. Mirrors the standard chat roles; `.tool` carries a tool
/// step's outcome back into the thread.
public enum AgentRole: String, Codable, Sendable {
    case user, assistant, system, tool
}

/// One message in a conversation — the atom of a thread.
///
/// `text` is the committed user/response content (the contract for *what is re-fed*). `thinking` is the
/// model's reasoning (the contract for *what is shown but never re-fed*). See the file-level invariant.
public struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var role: AgentRole
    /// The committed user/response text — NEVER the thinking. This is the only content re-fed on a
    /// later turn (assembly reads this field exclusively).
    public var text: String
    /// The model's reasoning, retained for DISPLAY only; never re-fed verbatim as ground truth.
    public var thinking: String?
    /// The turn's ordered thinking/answer TIMELINE (`notch-timeline-and-tuning`), retained for DISPLAY
    /// only like `thinking` — never re-fed, structurally excluded from assembly. Optional and decode-safe:
    /// a message persisted before this field renders via the `displaySegments` legacy fallback.
    public var segments: [TurnSegment]?
    /// The turn's images (each PNG); a SINGLE turn may carry MULTIPLE images (design D2 — a multi-image
    /// turn). Empty for a text-only turn. `LLMChatRequest.images` forwards the latest turn's full array.
    public var images: [Data]
    /// An assistant turn that routed to tools (type owned by `ai-tool-routing`; see `ToolPlaceholders`).
    public var toolCalls: [ToolRoute]?
    /// For `role == .tool`: the executed step's outcome (owned by `ai-tool-routing`).
    public var toolResult: ToolStepResult?
    public var createdAt: Date

    /// The turn's FIRST image, or nil when it carries none — the single-image convenience kept for callers
    /// and assembly that only need one image (design D2: `images` is the source of truth; this is derived).
    public var image: Data? { images.first }

    /// The message's display TIMELINE: the persisted `segments` when present, else the legacy fallback —
    /// the flat `thinking` (a message stored before segments existed) as one leading thinking block,
    /// followed by the committed `text` as one answer block. The single read every transcript renderer
    /// uses, so old and new messages draw through the same path.
    public var displaySegments: [TurnSegment] {
        if let segments, !segments.isEmpty { return segments }
        var out: [TurnSegment] = []
        if let thinking, !thinking.isEmpty { out.append(TurnSegment(kind: .thinking, text: thinking)) }
        out.append(TurnSegment(kind: .answer, text: text))
        return out
    }

    /// Designated init. `images` defaults to `[]`; the `image:` convenience init folds a single image in.
    public init(id: UUID = UUID(),
                role: AgentRole,
                text: String,
                thinking: String? = nil,
                segments: [TurnSegment]? = nil,
                images: [Data] = [],
                toolCalls: [ToolRoute]? = nil,
                toolResult: ToolStepResult? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.thinking = thinking
        self.segments = segments
        self.images = images
        self.toolCalls = toolCalls
        self.toolResult = toolResult
        self.createdAt = createdAt
    }

    /// Single-image convenience (design D2): folds one optional image into the `images` array so existing
    /// callers (`AgentMessage(... image: png)`) keep compiling unchanged. A nil image yields `[]`.
    public init(id: UUID = UUID(),
                role: AgentRole,
                text: String,
                thinking: String? = nil,
                image: Data?,
                toolCalls: [ToolRoute]? = nil,
                toolResult: ToolStepResult? = nil,
                createdAt: Date = Date()) {
        self.init(id: id, role: role, text: text, thinking: thinking, segments: nil,
                  images: image.map { [$0] } ?? [],
                  toolCalls: toolCalls, toolResult: toolResult, createdAt: createdAt)
    }

    // MARK: Codable (tolerant decode)
    //
    // The image field migrated from a single `image: Data?` to `images: [Data]` (design D2). A custom
    // decoder accepts EITHER the new `images` array OR a legacy singular `image` value (folded into the
    // array), defaulting to `[]` — so a conversation persisted under the old shape still decodes. Encode
    // always writes the new `images` array (the singular key is decode-only legacy tolerance).
    private enum CodingKeys: String, CodingKey {
        case id, role, text, thinking, segments, images, image, toolCalls, toolResult, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(AgentRole.self, forKey: .role)
        self.text = try c.decode(String.self, forKey: .text)
        self.thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        self.segments = try c.decodeIfPresent([TurnSegment].self, forKey: .segments)
        if let arr = try c.decodeIfPresent([Data].self, forKey: .images) {
            self.images = arr
        } else if let single = try c.decodeIfPresent(Data.self, forKey: .image) {
            self.images = [single]
        } else {
            self.images = []
        }
        self.toolCalls = try c.decodeIfPresent([ToolRoute].self, forKey: .toolCalls)
        self.toolResult = try c.decodeIfPresent(ToolStepResult.self, forKey: .toolResult)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encodeIfPresent(segments, forKey: .segments)
        try c.encode(images, forKey: .images)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolResult, forKey: .toolResult)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// The session identity threaded through EVERY slice — one opaque value, stable across park/restore (the
/// parked slice persists a conversation under this id; the batched runtime keys its streams by it).
public struct AgentSessionID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

/// An ordered conversation: a message list with a title and timestamps. `Codable` so the parked-sessions
/// slice can persist it — but THIS slice owns only the type, not the durable store (no duplication).
public struct AgentConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentSessionID
    /// Short, model- or first-turn-derived; shown on the rail/badge by the parked slice.
    public var title: String
    public var messages: [AgentMessage]
    public var createdAt: Date
    public var updatedAt: Date
    /// Compaction output: a prefix summary that replaces dropped older turns (see `ConversationCompactor`).
    public var compactedSummary: String?
    /// The active skill (file id) driving this session, if any (owned by `ai-skills-as-files`).
    public var skillID: String?
    /// The per-conversation auto-approve grant (`add-voice-computer-use-agent`, design D7): while
    /// true, `.confirm`-tier acts execute without a per-step pause (narrated). Granted only through
    /// the gated `enable_auto_mode` / a surface toggle / a parsed initial-command intent; revocation
    /// is instant. Persisted with the conversation. Optional so rows stored by older builds decode
    /// cleanly (nil reads as false).
    public var autoApprove: Bool?
    /// BORN-WITH tuning (`notch-timeline-and-tuning`): the reasoning flag this conversation was created
    /// under. Stamped at birth from the notch tuning slider and carried for the conversation's whole
    /// life — a later slider change never retunes an existing session. Optional and decode-safe: nil
    /// (a pre-change conversation) falls back to the surface's global reasoning default at bind time.
    public var reasoningOverride: Bool?
    /// BORN-WITH tuning: the context-token budget this conversation was created under (already clamped
    /// to the model max at birth). Feeds compaction for this conversation only. Optional and
    /// decode-safe: nil falls back to the engine's injected budget.
    public var contextTokens: Int?

    /// The effective grant (nil-safe read).
    public var isAutoApproveGranted: Bool { autoApprove ?? false }

    public init(id: AgentSessionID = AgentSessionID(),
                title: String,
                messages: [AgentMessage],
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                compactedSummary: String? = nil,
                skillID: String? = nil,
                autoApprove: Bool? = nil,
                reasoningOverride: Bool? = nil,
                contextTokens: Int? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.compactedSummary = compactedSummary
        self.skillID = skillID
        self.autoApprove = autoApprove
        self.reasoningOverride = reasoningOverride
        self.contextTokens = contextTokens
    }
}

/// A single conversational turn unit fed to the runtime (AFTER compaction is applied) — the transient,
/// in-memory product of "windowed/compacted messages + the latest image + per-turn reasoning +
/// parameters". Not `Codable` (only `AgentConversation` persists).
public struct AgentTurn: Sendable {
    public var messages: [AgentMessage]
    public var image: Data?
    public var reasoning: Bool
    public var parameters: GenerationParameters

    public init(messages: [AgentMessage],
                image: Data? = nil,
                reasoning: Bool = false,
                parameters: GenerationParameters = .default) {
        self.messages = messages
        self.image = image
        self.reasoning = reasoning
        self.parameters = parameters
    }
}
