import Foundation

/// Per-skill configuration for handing a task off to Claude Code (blueprint §3.8). DEFINED HERE because
/// `ai-skills-as-files` (Wave 3) needs to carry it on a skill manifest, but it is logically OWNED by
/// `ai-claude-handoff` (Wave 4), which uses this type for the `launch_claude` tool + the budget cap.
/// Wave 4 USES this definition; it does not redefine it (single definition in Core).
struct ClaudeHandoffConfig: Codable, Equatable, Sendable {
    /// Whether a handoff for this skill runs automatically or asks each time. Default `.confirm` (money).
    var confirmMode: HandoffConfirmMode
    /// The folder Claude is launched in (nil = the contextual/current folder).
    var folder: String?
    /// A starting prompt handed to Claude on launch.
    var startingPrompt: String?
    /// A per-day budget cap on automatic handoffs (nil = use the global cap).
    var maxPerDay: Int?

    init(confirmMode: HandoffConfirmMode = .confirm, folder: String? = nil,
         startingPrompt: String? = nil, maxPerDay: Int? = nil) {
        self.confirmMode = confirmMode
        self.folder = folder
        self.startingPrompt = startingPrompt
        self.maxPerDay = maxPerDay
    }
}

/// Whether a Claude handoff is automatic (no per-call confirm, budget-capped) or confirmed each time.
enum HandoffConfirmMode: String, Codable, Equatable, Sendable {
    case auto
    case confirm
}
