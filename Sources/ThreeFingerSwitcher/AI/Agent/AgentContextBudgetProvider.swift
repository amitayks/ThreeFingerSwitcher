import Foundation

/// Reads an optional per-skill context-override (design D5). The value rides on the skill file (owned by
/// `ai-skills-as-files`); this slice only READS it through this seam. The default returns nil (no skill
/// raises the context).
protocol SkillContextOverriding: Sendable {
    /// The context-token override the active skill declares, if any.
    func contextOverride(forSkill skillID: String?) -> Int?
}

/// The default: no skill raises the context (used until `ai-skills-as-files` supplies a real source).
struct NoSkillContextOverride: SkillContextOverriding {
    init() {}
    func contextOverride(forSkill skillID: String?) -> Int? { nil }
}

/// The CONCRETE context budget (design D5, integration fix C3). It conforms to `ai-conversation-runtime`'s
/// `ContextBudgetProviding` — that protocol is OWNED there; this slice supplies the concrete value, so
/// conversation-runtime's compaction reads the same budget the user chose without a DAG back-edge.
///
/// The effective budget is the user's `agentContextTokens`, raised to a heavy skill's override if larger,
/// and CLAMPED to the model's architectural `maxContextTokens` — so growing the slider directly raises the
/// compaction trigger and the two never disagree about "the budget."
struct AgentContextBudgetProvider: ContextBudgetProviding {
    let userContextTokens: Int
    let modelMaxContextTokens: Int
    let activeSkillID: String?
    let skillOverrides: SkillContextOverriding

    init(userContextTokens: Int,
         modelMaxContextTokens: Int,
         activeSkillID: String? = nil,
         skillOverrides: SkillContextOverriding = NoSkillContextOverride()) {
        self.userContextTokens = userContextTokens
        self.modelMaxContextTokens = modelMaxContextTokens
        self.activeSkillID = activeSkillID
        self.skillOverrides = skillOverrides
    }

    var maxContextTokens: Int {
        let skillRaise = skillOverrides.contextOverride(forSkill: activeSkillID) ?? 0
        let desired = max(userContextTokens, skillRaise)
        return min(max(1, desired), max(1, modelMaxContextTokens))   // ∩ model max, never below 1
    }
}
