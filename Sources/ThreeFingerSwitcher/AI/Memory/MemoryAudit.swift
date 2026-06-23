import Foundation

/// The audit seam this slice emits into (design §4 / task §6.3). `AuditRecord`/`AuditLog` are OWNED by
/// `ai-background-autonomy` (Wave 4) — when that slice lands it supplies the production conformer and the
/// durable log; this slice ships the protocol + a record so it compiles + tests its emission without a
/// DAG back-edge. Mirrors the `WritePolicyResolving`/`DescriptorWritePolicy` stand-in discipline.
///
/// EVERY memory invoke (read included) emits one record. The `argumentsSummary` is REDACTED/SHORT — a
/// subfile name + a content length, never the raw secret content (design §4: "redacted/short").

/// One audited memory operation.
struct MemoryAuditRecord: Equatable, Sendable {
    var sessionID: AgentSessionID?
    var tool: String
    var policy: WritePolicyTier
    /// Redacted/short — never the raw content (e.g. `scope=subfile name=acme len=812`).
    var argumentsSummary: String
    var outcome: MemoryAuditOutcome
    var wasBackground: Bool
    var timestamp: Date

    init(sessionID: AgentSessionID?, tool: String, policy: WritePolicyTier, argumentsSummary: String,
         outcome: MemoryAuditOutcome, wasBackground: Bool, timestamp: Date = Date()) {
        self.sessionID = sessionID
        self.tool = tool
        self.policy = policy
        self.argumentsSummary = argumentsSummary
        self.outcome = outcome
        self.wasBackground = wasBackground
        self.timestamp = timestamp
    }
}

/// The outcome of an audited memory op (mirrors `ToolStepStatus` but audit-shaped).
enum MemoryAuditOutcome: Equatable, Sendable {
    case done
    case declined(reason: String)
    case failed(headline: String)
}

/// The sink memory writes its audit records into. `ai-background-autonomy` owns the durable conformer;
/// this slice injects it (tests inject a recording fake).
protocol MemoryAuditing: Sendable {
    func record(_ record: MemoryAuditRecord)
}

/// A no-op default so the store/provider compile + run without the audit slice present.
struct NullMemoryAuditing: MemoryAuditing {
    init() {}
    func record(_ record: MemoryAuditRecord) {}
}
