import Foundation

/// The mutable, thread-safe budget holder the contributor records spend against (`ai-claude-handoff`).
/// `HandoffBudget` is a PURE value type; this reference wrapper owns the single mutable instance + its
/// persistence so the `Sendable` contributor can `record`/`reap`/`refund` across an `await` without
/// data races. Reads (`allows`) snapshot under the lock. MLX-free Core.
final class HandoffBudgetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: HandoffBudget
    private let store: HandoffLedgerStore

    init(maxCallsPerDay: Int, maxConcurrent: Int = 1, store: HandoffLedgerStore = InMemoryHandoffLedgerStore()) {
        self.store = store
        // Seed the ledger from disk so the rolling-window cap survives a relaunch.
        self.budget = HandoffBudget(maxCallsPerDay: maxCallsPerDay, maxConcurrent: maxConcurrent,
                                    ledger: store.load())
    }

    func allows(now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return budget.allows(now: now)
    }

    func record(at: Date, skillID: String?) {
        lock.lock(); defer { lock.unlock() }
        budget.record(at: at, skillID: skillID)
        store.save(budget.ledger)
    }

    func reap() {
        lock.lock(); defer { lock.unlock() }
        budget.reap()
    }

    func refund(at: Date) {
        lock.lock(); defer { lock.unlock() }
        budget.refund(at: at)
        store.save(budget.ledger)
    }

    /// A snapshot for assertions / tests.
    func snapshot() -> HandoffBudget {
        lock.lock(); defer { lock.unlock() }
        return budget
    }
}

/// The resolved effective gate for one handoff call (`ai-claude-handoff`, design Decision 4). The
/// descriptor is ALWAYS `.dangerous`; the per-skill `auto` opt-in is an effective-tier downgrade resolved
/// HERE (never a descriptor change), and only WITHIN what the user whitelist permits.
enum HandoffGate: Equatable {
    /// The skill carries handoff but it is off (or the resolved cap is 0) → declined, no spend.
    case disabled
    /// Skill `auto` AND under budget AND whitelist permits → run now, no per-call approval (still audited).
    case autoRun
    /// Default-confirm (or whitelist keeps it dangerous) → foreground DOWN=approve / RIGHT=skip.
    case needsApproval
    /// Over the daily cap → degrade to a foreground confirm (active) / needs-you (parked); never auto-run.
    case overBudget
}

/// The `launch_claude` capability as a `ToolContributor` (`ai-claude-handoff`, design Decision 2–4). It
/// projects a single `.dangerous` descriptor and, on `run`, resolves the effective cost gate (skill
/// confirm-mode ∩ user whitelist ∩ budget), audits exactly one outcome, and — when permitted — reuses the
/// open-claude-here `.command` handoff to fire Claude FIRE-AND-FORGET. The round-trip (consume Claude's
/// output, resume the conversation) is a documented future; the seam is left, the behavior is not built.
/// MLX-free Core; `swift test`-verified with a fake launcher + scripted gate + recording audit/escalation.
struct ClaudeHandoffContributor: ToolContributor {
    /// The active skill's handoff config (or `.init()` for a default-confirm free handoff).
    let config: ClaudeHandoffConfig
    /// The mutable, persisted budget the call records against.
    let budget: HandoffBudgetBox
    /// The side-effecting spawn (production = `OpenClaudeHandoffLauncher`; tests = a recording fake).
    let launcher: HandoffLauncher
    /// The shared append-only audit log seam.
    let audit: HandoffAuditing
    /// The whitelist-aware effective-tier resolver (descriptor default ∩ user whitelist).
    let resolver: WritePolicyResolving
    /// Parked → needs-you escalation seam.
    let escalation: HandoffEscalating
    /// The session this contributor serves (for the audit record's attribution).
    let sessionID: AgentSessionID
    /// The active skill id (for the spend ledger's attribution); nil for a free handoff.
    let skillID: String?
    /// True when the session is parked (background) — routes a needs-approval call to escalation.
    let isParked: Bool
    /// The global per-window default cap when the skill's `maxPerDay` is nil/0.
    let globalDefaultPerDay: Int
    /// The injected clock (deterministic, `DockHoverModel`-style).
    let now: @Sendable () -> Date

    static let toolName = "launch_claude"

    init(config: ClaudeHandoffConfig = ClaudeHandoffConfig(),
         budget: HandoffBudgetBox,
         launcher: HandoffLauncher,
         audit: HandoffAuditing = NoopHandoffAudit(),
         resolver: WritePolicyResolving = DescriptorWritePolicy(),
         escalation: HandoffEscalating = NoopHandoffEscalation(),
         sessionID: AgentSessionID = AgentSessionID(),
         skillID: String? = nil,
         isParked: Bool = false,
         globalDefaultPerDay: Int = 10,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.budget = budget
        self.launcher = launcher
        self.audit = audit
        self.resolver = resolver
        self.escalation = escalation
        self.sessionID = sessionID
        self.skillID = skillID
        self.isParked = isParked
        self.globalDefaultPerDay = globalDefaultPerDay
        self.now = now
    }

    // MARK: - Descriptor

    /// The single `launch_claude` descriptor — ALWAYS `.dangerous` (the `auto` opt-in is a per-skill
    /// effective-tier downgrade, NOT a descriptor change, so the router never sees a globally-auto
    /// handoff).
    static func descriptor() -> ToolDescriptor {
        let schema = StructuredSchema(name: toolName, json: """
        {"type":"object","required":["prompt"],"properties":{\
        "folder":{"type":"string","description":"absolute path to open Claude in; omit to use the skill's default working directory"},\
        "prompt":{"type":"string","description":"the starting prompt Claude opens with"}}}
        """)
        return ToolDescriptor(
            name: toolName,
            summary: "Hand the task to Claude Code in a folder with a starting prompt — use when the task exceeds the local model.",
            argsSchema: schema,
            writePolicy: .dangerous,
            keywords: ["claude", "handoff", "escalate", "code", "refactor", "big task"])
    }

    func descriptors() -> [ToolDescriptor] { [Self.descriptor()] }

    func canHandle(_ tool: String) -> Bool { tool == Self.toolName }

    // MARK: - Effective gate (the cost gate)

    /// Resolve the resolved per-window cap: the skill's `maxPerDay` when set (> 0), else the global
    /// default. A resolved cap of 0 means handoff is disabled.
    var resolvedCap: Int {
        if let perDay = config.maxPerDay, perDay > 0 { return perDay }
        return globalDefaultPerDay
    }

    /// The effective gate for THIS call (design Decision 4). Whitelist intersects the descriptor's
    /// `.dangerous` FIRST: a user who has NOT whitelisted handoff keeps it `.dangerous` →
    /// `.needsApproval`/needs-you regardless of the skill's `auto`.
    func effectiveGate() -> HandoffGate {
        // Disabled: a 0 resolved cap means the user/global turned handoff off.
        guard resolvedCap > 0 else { return .disabled }

        // The whitelist-aware tier: .dangerous can NEVER be lowered to .auto by the resolver, so a
        // non-whitelisted handoff stays dangerous → always foreground. Only when the resolver lowers the
        // descriptor below dangerous AND the skill opted auto can the call run unprompted.
        let effectiveTier = resolver.effectiveTier(for: Self.descriptor())
        let whitelistPermitsAuto = (effectiveTier != .dangerous)

        if !budget.allows(now: now()) { return .overBudget }

        switch config.confirmMode {
        case .auto:
            return whitelistPermitsAuto ? .autoRun : .needsApproval
        case .confirm:
            return .needsApproval
        }
    }

    // MARK: - Run (the state machine)

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        let toolName = call.descriptor.name

        // Folder resolution: route folder → skill default → fail clean (no spend).
        guard let folder = resolveFolder(call) else {
            await emit(outcome: .failed(headline: HandoffError.missingFolder.errorDescription ?? ""),
                       folder: nil, prompt: prompt(call))
            return ToolStepResult(tool: toolName,
                                  status: .failed(headline: AIError.message(for: HandoffError.missingFolder).headline),
                                  summary: "Couldn't open Claude: no folder.")
        }

        let promptText = prompt(call)

        switch effectiveGate() {
        case .disabled:
            let reason = AIError.message(for: HandoffError.disabled).headline
            await emit(outcome: .declined(reason: reason), folder: folder, prompt: promptText)
            return ToolStepResult(tool: toolName, status: .declined(reason: reason), summary: reason)

        case .autoRun:
            // Skill auto, under budget, whitelist permits — runs even when parked (audited).
            return await spendAndLaunch(toolName: toolName, folder: folder, prompt: promptText, background: isParked)

        case .needsApproval:
            return await confirmThenLaunch(toolName: toolName, folder: folder, prompt: promptText,
                                           gate: gate, overBudget: false)

        case .overBudget:
            // Never auto-run over budget, never silently dropped. Active → degrade to a foreground confirm;
            // parked → escalate to needs-you (no spend until the user returns).
            return await confirmThenLaunch(toolName: toolName, folder: folder, prompt: promptText,
                                           gate: gate, overBudget: true)
        }
    }

    /// The confirm / over-budget path: parked → escalate (needs-you); active → await the gate.
    private func confirmThenLaunch(toolName: String, folder: URL, prompt: String,
                                   gate: ApprovalGate, overBudget: Bool) async -> ToolStepResult {
        let cardReason = overBudget
            ? "Daily Claude handoff limit reached. Approve to open Claude in \(folder.lastPathComponent)?"
            : "Hand this to Claude Code in \(folder.lastPathComponent)?"

        if isParked {
            // Dangerous-while-parked escalates: needs-you badge, no spend until the user returns.
            await escalation.escalate(sessionID, reason: cardReason)
            await emit(outcome: .awaitingApproval, folder: folder, prompt: prompt)
            return ToolStepResult(tool: toolName, status: .awaitingApproval, summary: cardReason)
        }

        let review = TaskReview.action(title: "Open Claude Code",
                                       fields: [ReviewField("Folder", folder.path),
                                                ReviewField("Prompt", AuditRedaction.summary(forRawArguments: prompt))],
                                       payload: .openTool(tool: Self.toolName,
                                                          action: ParsedOpenTool(applicable: true, reason: nil, payload: prompt)))
        switch await gate.awaitDecision(for: review) {
        case .approve:
            return await spendAndLaunch(toolName: toolName, folder: folder, prompt: prompt, background: false)
        case .skip:
            let reason = "skipped"
            await emit(outcome: .declined(reason: reason), folder: folder, prompt: prompt)
            return ToolStepResult(tool: toolName, status: .declined(reason: reason),
                                  summary: "Skipped the Claude handoff.")
        case .cancel:
            // The whole canvas was discarded — end the loop quietly (NOT a failure), no spend, no launch.
            await emit(outcome: .declined(reason: TaskKindToolContributor.cancelledReason),
                       folder: folder, prompt: prompt)
            return ToolStepResult(tool: toolName,
                                  status: .declined(reason: TaskKindToolContributor.cancelledReason),
                                  summary: "Cancelled.")
        }
    }

    /// Record the spend, audit, fire fire-and-forget. A launch that throws → `.failed` + refund (a handoff
    /// that didn't land didn't spend). V1: reap immediately after a successful open.
    private func spendAndLaunch(toolName: String, folder: URL, prompt: String, background: Bool) async -> ToolStepResult {
        let at = now()
        budget.record(at: at, skillID: skillID)
        do {
            try await launcher.launch(folder: folder, prompt: prompt)
            budget.reap()
            await emit(outcome: .done, folder: folder, prompt: prompt, background: background)
            return ToolStepResult(tool: toolName, status: .done,
                                  summary: "Opened Claude Code in \(folder.lastPathComponent).")
        } catch {
            budget.refund(at: at)   // a launch that didn't land didn't spend — the cap stays honest.
            let headline = AIError.message(for: error).headline
            await emit(outcome: .failed(headline: headline), folder: folder, prompt: prompt, background: background)
            return ToolStepResult(tool: toolName, status: .failed(headline: headline),
                                  summary: "Couldn't open Claude Code.")
        }
    }

    // MARK: - Folder / prompt extraction

    private func resolveFolder(_ call: RoutedCall) -> URL? {
        if let routed = stringArg(call, "folder")?.trimmingCharacters(in: .whitespacesAndNewlines), !routed.isEmpty {
            return URL(fileURLWithPath: (routed as NSString).expandingTildeInPath)
        }
        if let dir = config.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return nil
    }

    private func prompt(_ call: RoutedCall) -> String {
        if let p = stringArg(call, "prompt"), !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return p
        }
        // Fall back to the skill's configured starting prompt, then the user's text.
        if let sp = config.startingPrompt, !sp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sp
        }
        return ""   // empty → a bare claude session (allowed)
    }

    private func stringArg(_ call: RoutedCall, _ key: String) -> String? {
        guard let data = call.route.argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    // MARK: - Audit (one record per outcome; redacted summary)

    /// Emit EXACTLY one audit record for this outcome. `argumentsSummary` is the folder + a TRUNCATED
    /// prompt — NEVER the full prompt verbatim (a prompt can carry secrets; raw text rides only in logs).
    private func emit(outcome: ToolStepStatus, folder: URL?, prompt: String, background: Bool? = nil) async {
        let folderPart = folder.map { AuditRedaction.lastComponents($0.path) } ?? "(no folder)"
        let promptPart = AuditRedaction.summary(forRawArguments: prompt)
        let summary = AuditRedaction.middleTruncate("\(folderPart) · \(promptPart)",
                                                    to: AuditRedaction.maxSummaryLength)
        let record = AuditRecord(sessionID: sessionID,
                                 tool: Self.toolName,
                                 policy: .dangerous,
                                 argumentsSummary: summary,
                                 outcome: outcome,
                                 wasBackground: background ?? isParked,
                                 timestamp: now())
        await audit.record(record)
    }
}
