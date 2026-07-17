import Foundation

/// The HONEST upload + cost disclosure for a video generation (`ai-video-animation-generation`, design D4 /
/// tasks 1.2, 7.1, 7.2). A pure value so the confirm step AND the audit summary are testable WITHOUT
/// network: it states whether bytes leave the device, builds the REDACTED argument summary (provider +
/// TRUNCATED prompt + seed-present flag — never the full prompt verbatim, never the raw seed bytes), and —
/// for the cloud provider — carries the per-clip $ order; for local, the residency/heat/eviction cost.
///
/// Redaction rule (blueprint): raw prompt text and raw seed bytes ride ONLY in logs / behind an opt-in
/// "Show details" disclosure — NEVER in the headline, NEVER in the audit summary. This builder enforces it
/// by middle-truncating the prompt through `AuditRedaction` and reducing the seed to a boolean. MLX-free
/// Core.
public struct VideoUploadDisclosure: Equatable, Sendable {
    /// True iff the generation sends bytes off-device (the prompt + any seed frame). Cloud → true; local →
    /// false (nothing is uploaded — spec "Local video does not claim an upload").
    public let bytesLeaveDevice: Bool
    /// Which backend (cloud / local LTXV) — surfaced on the confirm step + recorded in the audit summary.
    public let provider: VideoProvider
    /// A TRUNCATED, single-line prompt preview (never the full prompt). Built through `AuditRedaction` so a
    /// secret-shaped token is scrubbed + the line is bounded.
    public let truncatedPrompt: String
    /// Whether a seed IMAGE was sent (img2video). A boolean — the raw seed bytes NEVER appear here.
    public let seedPresent: Bool

    public init(bytesLeaveDevice: Bool,
                provider: VideoProvider,
                truncatedPrompt: String,
                seedPresent: Bool) {
        self.bytesLeaveDevice = bytesLeaveDevice
        self.provider = provider
        self.truncatedPrompt = truncatedPrompt
        self.seedPresent = seedPresent
    }

    /// Build the disclosure for a routed video request. `provider.isCloud` decides `bytesLeaveDevice`; the
    /// prompt is middle-truncated + secret-scrubbed; the seed is reduced to a present/absent flag.
    public static func make(provider: VideoProvider, prompt: String, seedPresent: Bool) -> VideoUploadDisclosure {
        VideoUploadDisclosure(
            bytesLeaveDevice: provider.isCloud,
            provider: provider,
            truncatedPrompt: AuditRedaction.summary(forRawArguments: prompt),
            seedPresent: seedPresent
        )
    }

    // MARK: - Audit summary (the redacted record line)

    /// The single-line REDACTED argument summary for the audit record (task 4.1): provider · truncated
    /// prompt · seed flag. Bounded to `AuditRedaction.maxSummaryLength`; the full prompt / raw seed bytes
    /// are NEVER present. This is the SOLE string that reaches `AuditRecord.argumentsSummary` for a video
    /// attempt.
    public var auditSummary: String {
        let seedTag = seedPresent ? "seed:yes" : "seed:no"
        let promptPart = truncatedPrompt.isEmpty ? "(no prompt)" : truncatedPrompt
        let line = "\(provider.rawValue) · \(promptPart) · \(seedTag)"
        return AuditRedaction.middleTruncate(line, to: AuditRedaction.maxSummaryLength)
    }

    // MARK: - Confirm-step copy (the user-facing disclosure)

    /// The CLOUD confirm-step line (task 7.1): states the bytes leave the device + the per-clip $ order
    /// (from `mediaVideoBudgetPerDay` semantics — the caller passes the per-clip cost order). Only meaningful
    /// when `bytesLeaveDevice`; for local it returns the residency/heat line instead via `localCostLine`.
    public func cloudConfirmLine(perClipCostOrder: String) -> String {
        guard bytesLeaveDevice else { return Self.localCostLine }
        let seedClause = seedPresent ? " and your source image" : ""
        return "Your prompt\(seedClause) will be sent to the remote video service "
            + "(\(perClipCostOrder) per clip, from today's budget)."
    }

    /// The LOCAL-LTXV selection disclosure (task 7.2): tens-of-GB residency, minutes-per-clip latency, chat
    /// EVICTION (the assistant goes quiet while it paints — consumed from the fleet residency decision §C1),
    /// and the thermal cost. Stated in the same breath the frontier is offered (spec "Selecting local LTXV
    /// discloses its cost"). A static line — local video spends no money, so there is no $ to disclose.
    public static let localCostLine =
        "Local video is a frontier option: tens of gigabytes of weights, minutes per clip, the assistant "
        + "goes quiet while it paints (chat is evicted), and your Mac runs hot. Nothing is uploaded."
}
