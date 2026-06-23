import Foundation

/// One append-only audit log entry (`ai-background-autonomy`, blueprint §3.7 / design Decision 5). Every
/// agent tool step writes one — auto, confirmed, declined, escalated, or failed — so the ledger is a
/// complete "what did my agents do while I was away." CONSUMES `AgentSessionID` (`ai-conversation-runtime`)
/// + `WritePolicyTier`/`ToolStepStatus` (`ai-tool-routing`) verbatim. MLX-free Core.
public struct AuditRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// Attribution (the session that ran the step).
    public let sessionID: AgentSessionID
    /// The descriptor name.
    public let tool: String
    /// The EFFECTIVE tier this step ran at (post-resolution), not the descriptor default.
    public let policy: WritePolicyTier
    /// Redacted / short single-line summary — NEVER raw secrets or full bodies.
    public let argumentsSummary: String
    /// The outcome (a `.failed` carries a CLEAN headline only — `AIPresentedError.headline`).
    public let outcome: ToolStepStatus
    /// True if applied while the session was parked (background).
    public let wasBackground: Bool
    public let timestamp: Date

    public init(id: UUID = UUID(),
                sessionID: AgentSessionID,
                tool: String,
                policy: WritePolicyTier,
                argumentsSummary: String,
                outcome: ToolStepStatus,
                wasBackground: Bool,
                timestamp: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.policy = policy
        self.argumentsSummary = argumentsSummary
        self.outcome = outcome
        self.wasBackground = wasBackground
        self.timestamp = timestamp
    }
}

/// The pure `argumentsSummary` redaction builder (design Decision 5). Produces a bounded, single-line
/// summary safe to persist + show: the path's last component(s), a command name, a middle-truncated
/// content preview — never the full shell line with embedded secrets, never a raw body. Raw args go
/// nowhere near the record (they live only in the os.Logger breadcrumb at the sink boundary).
public enum AuditRedaction {
    /// The bounded length of a redacted summary (characters). Past this, the middle is elided with `…`.
    public static let maxSummaryLength = 80

    /// Redact a `PolicyTarget` into a short, safe summary.
    public static func summary(for target: PolicyTarget) -> String {
        switch target {
        case let .path(p):                return "→ " + lastComponents(p)
        case let .command(c):             return "$ " + commandName(c)
        case let .both(command, path):    return "$ " + commandName(command) + " → " + lastComponents(path)
        case .none:                       return ""
        }
    }

    /// Redact a free-form arguments string (e.g. a JSON args blob or a content preview): collapse
    /// whitespace to single lines, strip obvious secret-looking key=value pairs, and middle-truncate to
    /// the bounded length.
    public static func summary(forRawArguments raw: String) -> String {
        let singleLine = collapseWhitespace(raw)
        let scrubbed = scrubSecrets(singleLine)
        return middleTruncate(scrubbed, to: maxSummaryLength)
    }

    // MARK: - Helpers (pure)

    /// The command name only — `argv[0]`'s last path component, never the full line (which may carry an
    /// embedded token / secret as a later argument).
    static func commandName(_ command: String) -> String {
        let argv0 = collapseWhitespace(command).split(separator: " ").first.map(String.init) ?? command
        let name = (argv0 as NSString).lastPathComponent
        return middleTruncate(name, to: maxSummaryLength)
    }

    /// The last 1–2 path components of a path, so the record says *where* without leaking the full tree.
    static func lastComponents(_ path: String) -> String {
        let std = Whitelist.standardize(path)
        let parts = std.split(separator: "/").map(String.init)
        let tail = parts.suffix(2).joined(separator: "/")
        let shown = tail.isEmpty ? std : ".../" + tail
        return middleTruncate(shown, to: maxSummaryLength)
    }

    /// Collapse all runs of whitespace (incl. newlines) to a single space, trimmed.
    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Strip obvious secret-looking `key=value`/`key: value` pairs where the key smells sensitive,
    /// replacing the value with `***`. A best-effort scrub for the summary — the real defense is that we
    /// never emit raw bodies, only short summaries.
    static func scrubSecrets(_ s: String) -> String {
        let sensitive = ["token", "secret", "password", "passwd", "apikey", "api_key", "key", "auth", "bearer"]
        var out = s
        for word in sensitive {
            // key=VALUE  /  key: VALUE  /  --key VALUE  (VALUE = a run of non-space chars)
            let patterns = ["\(word)=\\S+", "\(word):\\s*\\S+", "--\(word)\\s+\\S+", "\(word)\\s+[A-Za-z0-9._\\-]{8,}"]
            for pat in patterns {
                if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                    let range = NSRange(out.startIndex..., in: out)
                    out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "\(word)=***")
                }
            }
        }
        return out
    }

    /// Middle-truncate with `…` so both the start and the end remain legible.
    static func middleTruncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        guard limit > 1 else { return "…" }
        let keep = limit - 1
        let head = keep - keep / 2
        let tail = keep / 2
        let start = s.prefix(head)
        let end = s.suffix(tail)
        return start + "…" + end
    }
}
