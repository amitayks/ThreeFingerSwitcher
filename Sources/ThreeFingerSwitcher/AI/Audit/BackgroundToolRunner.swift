import Foundation

/// Wraps a routed tool step with the background-autonomy policy (`ai-background-autonomy`, design
/// Decision 5/6 — tasks 6.1–6.4). For each step it: resolves the EFFECTIVE (whitelist-aware) tier via
/// `BackgroundPolicyResolver`, decides auto/foreground/waitParked/escalate by the session's `ParkState`
/// via `BackgroundGate`, runs / escalates / waits accordingly, and records an `AuditRecord` for EVERY
/// step. This is the App/integration seam `BackgroundGate` references; `AgentLoop` routes each tool step
/// through it when a session may run in the background (nil = the plain foreground path). MLX-free Core.
struct BackgroundToolRunner: Sendable {
    let resolver: BackgroundPolicyResolver
    let audit: AuditLog
    /// The parked-sessions escalation seam (`.dangerous` while parked → `.needsYou` + badge). Routed
    /// through the CONTROLLER (`ParkController.escalate` — persist + repaint), never a raw scheduler
    /// mutation, so a background needs-you survives relaunch and repaints the rail
    /// (`refactor-park-and-background-agents`). nil in a pure foreground context. Called OFF the main
    /// actor — the injector hops as needed.
    let onEscalate: (@Sendable (AgentSessionID, String) -> Void)?
    /// The session's current park state (keyed lookup; `.active` foreground by default).
    let parkStateOf: @Sendable (AgentSessionID) -> ParkState
    /// The routed call's whitelist target (per-tool; `.none` by default — calendar/contacts are never
    /// whitelist-lowerable).
    let targetOf: @Sendable (RoutedCall) -> PolicyTarget

    init(resolver: BackgroundPolicyResolver, audit: AuditLog,
         onEscalate: (@Sendable (AgentSessionID, String) -> Void)? = nil,
         parkStateOf: @escaping @Sendable (AgentSessionID) -> ParkState = { _ in .active },
         targetOf: @escaping @Sendable (RoutedCall) -> PolicyTarget = { _ in .none }) {
        self.resolver = resolver
        self.audit = audit
        self.onEscalate = onEscalate
        self.parkStateOf = parkStateOf
        self.targetOf = targetOf
    }

    /// Run one routed step under the policy, recording an audit row regardless of outcome (6.3/6.4).
    func run(_ call: RoutedCall, sessionID: AgentSessionID,
             registry: ToolRegistry, gate: ApprovalGate) async -> ToolStepResult {
        let target = targetOf(call)
        let tier = resolver.effectiveTier(for: call.descriptor, target: target)
        let parkState = parkStateOf(sessionID)
        let decision = BackgroundGate.decide(effectiveTier: tier, parkState: parkState, tool: call.descriptor.name)

        let result: ToolStepResult
        switch decision {
        case .auto:
            // Policy already cleared it — run without prompting. The auto-approving gate bridges a
            // contributor that still resolves `.confirm` on the descriptor-only fast path.
            result = await registry.run(call, gate: AutoApproveGate())
        case .foreground:
            result = await registry.run(call, gate: gate)   // the canvas approval gate owns confirm here
        case .waitParked:
            // The loop PAUSES on this status (`.pausedAwaitingUser`) — the step is genuinely pending,
            // resolved when the user brings the session back; never silently skipped-and-continued.
            result = ToolStepResult(tool: call.descriptor.name, status: .awaitingApproval,
                                    summary: "Waiting for your approval.")
        case let .escalate(reason):
            onEscalate?(sessionID, reason)
            result = ToolStepResult(tool: call.descriptor.name, status: .awaitingApproval, summary: reason)
        }

        // EVERY step is audited (6.4): the EFFECTIVE tier, a redacted args summary, the outcome, and the
        // background flag. record(_:) is non-blocking + infallible — auditing never breaks the agent.
        let targetSummary = AuditRedaction.summary(for: target)
        audit.record(AuditRecord(
            sessionID: sessionID,
            tool: call.descriptor.name,
            policy: tier,
            argumentsSummary: targetSummary.isEmpty
                ? AuditRedaction.summary(forRawArguments: call.route.argumentsJSON)
                : targetSummary,
            outcome: result.status,
            wasBackground: parkState != .active))
        return result
    }
}

/// An approval gate that auto-approves — used by `BackgroundToolRunner` for an `.auto`-tier background
/// step the policy has already cleared (so a contributor never prompts for an already-authorized run).
struct AutoApproveGate: ApprovalGate {
    func awaitDecision(for review: TaskReview) async -> ApprovalDecision { .approve }
}
