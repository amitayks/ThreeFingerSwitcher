import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the Claude-handoff escalation slice (`ai-claude-handoff`): the `launch_claude` descriptor
/// (always `.dangerous`), the rolling-24h budget cap (cap / window / concurrency / refund / persistence),
/// the production launcher's prompt→inner-command + error mapping, and the contributor's cost-gate state
/// machine (confirm gates, auto-under-budget runs, auto-over-budget escalates to confirm, fire-and-forget
/// fires the opener exactly once, parked escalation, redacted audit on every branch). All driven by a
/// fake `HandoffLauncher` + scripted `ApprovalGate` + recording audit/escalation — no real spawn.
final class ClaudeHandoffTests: XCTestCase {

    // MARK: - Fakes

    /// A launcher that records every `(folder, prompt)` and can be scripted to throw.
    private final class FakeLauncher: HandoffLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(folder: URL, prompt: String)] = []
        var throwError: Error?

        func launch(folder: URL, prompt: String) async throws {
            lock.lock(); calls.append((folder, prompt)); let e = throwError; lock.unlock()
            if let e { throw e }
        }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    }

    private final class ScriptedGate: ApprovalGate, @unchecked Sendable {
        private let lock = NSLock()
        private var decisions: [ApprovalDecision]
        private(set) var asked = 0
        init(_ decisions: [ApprovalDecision]) { self.decisions = decisions }
        func awaitDecision(for review: TaskReview) async -> ApprovalDecision {
            lock.lock(); defer { lock.unlock() }
            asked += 1
            return decisions.isEmpty ? .cancel : decisions.removeFirst()
        }
    }

    private final class RecordingAudit: HandoffAuditing, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var records: [AuditRecord] = []
        func record(_ record: AuditRecord) async {
            lock.lock(); records.append(record); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    }

    private final class RecordingEscalation: HandoffEscalating, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var escalations: [(AgentSessionID, String)] = []
        func escalate(_ sessionID: AgentSessionID, reason: String) async {
            lock.lock(); escalations.append((sessionID, reason)); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return escalations.count }
    }

    /// A resolver that keeps the dangerous tier dangerous (the default whitelist behaviour — handoff is
    /// never whitelist-lowered to auto).
    private struct KeepDangerous: WritePolicyResolving {
        func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier { descriptor.writePolicy }
    }

    /// A resolver that lowers ANY tier to auto — models a user who whitelisted handoff (so a skill's auto
    /// can take effect).
    private struct WhitelistAuto: WritePolicyResolving {
        func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier { .auto }
    }

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func call(folder: String? = "/tmp/proj", prompt: String? = "fix the bug") -> RoutedCall {
        var props: [String: String] = [:]
        if let folder { props["folder"] = folder }
        if let prompt { props["prompt"] = prompt }
        let json = ((try? JSONSerialization.data(withJSONObject: props)).flatMap { String(data: $0, encoding: .utf8) }) ?? "{}"
        return RoutedCall(descriptor: ClaudeHandoffContributor.descriptor(),
                          route: ToolRoute(tool: ClaudeHandoffContributor.toolName, argumentsJSON: json),
                          userText: "please refactor", source: TaskSource())
    }

    // MARK: - Descriptor

    func testDescriptorIsAlwaysDangerous() {
        let d = ClaudeHandoffContributor.descriptor()
        XCTAssertEqual(d.name, "launch_claude")
        XCTAssertEqual(d.writePolicy, .dangerous)
        XCTAssertTrue(d.argsSchema.json.contains("\"prompt\""))
        XCTAssertTrue(d.argsSchema.json.contains("\"required\":[\"prompt\"]"))
    }

    func testCanHandle() {
        let c = makeContributor()
        XCTAssertTrue(c.canHandle("launch_claude"))
        XCTAssertFalse(c.canHandle("add_to_calendar"))
    }

    // MARK: - ClaudeHandoffConfig (existing type, consumed)

    func testConfigDefaultsToConfirm() throws {
        let cfg = ClaudeHandoffConfig()
        XCTAssertEqual(cfg.confirmMode, .confirm)
        // Codable round-trip; a config omitting confirmMode is invalid JSON for this struct, but a full
        // round-trip preserves the mode.
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(ClaudeHandoffConfig.self, from: data)
        XCTAssertEqual(back, cfg)
    }

    // MARK: - Budget

    func testBudgetAllowsUnderCapBlocksAtCap() {
        var b = HandoffBudget(maxCallsPerDay: 2, maxConcurrent: 5)
        XCTAssertTrue(b.allows(now: t0))
        b.record(at: t0); b.reap()
        XCTAssertTrue(b.allows(now: t0))
        b.record(at: t0); b.reap()
        XCTAssertFalse(b.allows(now: t0), "at the cap it must block")
    }

    func testBudgetRollingWindowNotCalendarDay() {
        // Two spends 25h apart: only the recent one is inside the 24h window ending at `now`.
        let old = t0
        let recent = t0.addingTimeInterval(25 * 3600)
        var b = HandoffBudget(maxCallsPerDay: 2, ledger: [HandoffSpend(at: old)])
        b.record(at: recent); b.reap()
        // now just after `recent`: the `old` spend has rolled out of the window.
        XCTAssertEqual(b.callsInLast24h(recent.addingTimeInterval(60)), 1)
        XCTAssertTrue(b.allows(now: recent.addingTimeInterval(60)))
    }

    func testBudgetMidnightCannotBeGamed() {
        // N at 23:59 and N at 00:01 fall in the same rolling window → counted together.
        let late = Date(timeIntervalSince1970: 1_700_000_000)             // some "23:59"
        let earlyNextDay = late.addingTimeInterval(2 * 60)               // 2 minutes later "00:01"
        var b = HandoffBudget(maxCallsPerDay: 2, ledger: [HandoffSpend(at: late)])
        b.record(at: earlyNextDay); b.reap()
        XCTAssertEqual(b.callsInLast24h(earlyNextDay), 2)
        XCTAssertFalse(b.allows(now: earlyNextDay), "no midnight reset — both count")
    }

    func testBudgetConcurrencyBlocks() {
        var b = HandoffBudget(maxCallsPerDay: 10, maxConcurrent: 1)
        b.record(at: t0)   // in-flight = 1, not reaped
        XCTAssertFalse(b.allows(now: t0), "in-flight at maxConcurrent blocks")
        b.reap()
        XCTAssertTrue(b.allows(now: t0))
    }

    func testBudgetRefundRestoresSlot() {
        var b = HandoffBudget(maxCallsPerDay: 1, maxConcurrent: 1)
        b.record(at: t0)
        XCTAssertFalse(b.allows(now: t0))
        b.refund(at: t0)
        XCTAssertEqual(b.callsInLast24h(t0), 0)
        XCTAssertEqual(b.inFlight, 0)
        XCTAssertTrue(b.allows(now: t0), "a refunded launch leaves the cap unchanged")
    }

    func testBudgetPersistsAcrossReload() {
        let store = InMemoryHandoffLedgerStore()
        let box1 = HandoffBudgetBox(maxCallsPerDay: 1, store: store)
        box1.record(at: t0, skillID: nil); box1.reap()
        XCTAssertFalse(box1.allows(now: t0))
        // A "relaunch": a fresh box over the same store still sees the spend in the window.
        let box2 = HandoffBudgetBox(maxCallsPerDay: 1, store: store)
        XCTAssertFalse(box2.allows(now: t0), "the cap survives a relaunch within the window")
    }

    // MARK: - Launcher prompt mapping + error mapping

    func testInnerCommandEmptyVsNonEmpty() {
        XCTAssertNil(OpenClaudeHandoffLauncher.innerCommand(forPrompt: "   "))
        XCTAssertNil(OpenClaudeHandoffLauncher.innerCommand(forPrompt: ""))
        let cmd = OpenClaudeHandoffLauncher.innerCommand(forPrompt: "fix it")
        XCTAssertEqual(cmd, "claude 'fix it'")
    }

    func testLaunchErrorMapping() {
        let notFound = OpenClaudeHandoffLauncher.map(.claudeNotFound)
        XCTAssertEqual(AIError.message(for: notFound).headline,
                       ClaudeLaunchError.claudeNotFound.errorDescription)
        let writeFail = OpenClaudeHandoffLauncher.map(.scriptWriteFailed(details: "disk full"))
        XCTAssertEqual(AIError.message(for: writeFail).details, "disk full",
                       "raw text rides only in details, not the headline")
        XCTAssertFalse(AIError.message(for: writeFail).headline.contains("disk full"))
    }

    func testHandoffErrorTranslatorCleanHeadlines() {
        for e in [HandoffError.disabled, .overBudgetNoUser, .missingFolder] {
            let m = AIError.message(for: e)
            XCTAssertFalse(m.headline.isEmpty)
            XCTAssertFalse(m.headline.contains("HandoffError"), "no raw enum dump in a headline")
        }
    }

    // MARK: - Contributor state machine

    private func makeContributor(config: ClaudeHandoffConfig = ClaudeHandoffConfig(),
                                 budget: HandoffBudgetBox? = nil,
                                 launcher: FakeLauncher = FakeLauncher(),
                                 audit: RecordingAudit = RecordingAudit(),
                                 escalation: RecordingEscalation = RecordingEscalation(),
                                 resolver: WritePolicyResolving = WhitelistAuto(),
                                 isParked: Bool = false,
                                 now: Date? = nil) -> ClaudeHandoffContributor {
        let clock = now ?? t0
        return ClaudeHandoffContributor(
            config: config,
            budget: budget ?? HandoffBudgetBox(maxCallsPerDay: 5),
            launcher: launcher,
            audit: audit,
            resolver: resolver,
            escalation: escalation,
            sessionID: AgentSessionID(),
            isParked: isParked,
            globalDefaultPerDay: 5,
            now: { clock })
    }

    func testConfirmSkillGatesAndApprovesLaunchesOnce() async {
        let launcher = FakeLauncher()
        let audit = RecordingAudit()
        let gate = ScriptedGate([.approve])
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .confirm),
                                launcher: launcher, audit: audit)
        let result = await c.run(call(), gate: gate)
        XCTAssertEqual(gate.asked, 1, "a confirm skill must gate")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(launcher.callCount, 1, "fire-and-forget: the opener fires exactly once")
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(audit.records.first?.outcome, .done)
    }

    func testConfirmSkillSkipDoesNotSpendOrLaunch() async {
        let launcher = FakeLauncher()
        let budget = HandoffBudgetBox(maxCallsPerDay: 5)
        let gate = ScriptedGate([.skip])
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .confirm),
                                budget: budget, launcher: launcher)
        let result = await c.run(call(), gate: gate)
        if case .declined = result.status {} else { XCTFail("skip → declined") }
        XCTAssertEqual(launcher.callCount, 0, "skip never launches")
        XCTAssertEqual(budget.snapshot().callsInLast24h(t0), 0, "skip never spends")
    }

    func testAutoSkillUnderBudgetRunsWithoutGate() async {
        let launcher = FakeLauncher()
        let gate = ScriptedGate([])   // must NOT be consulted
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto), launcher: launcher)
        let result = await c.run(call(), gate: gate)
        XCTAssertEqual(gate.asked, 0, "an auto skill under budget does not gate")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(launcher.callCount, 1)
    }

    func testAutoSkillRequiresWhitelistToRunUnprompted() async {
        // A user who did NOT whitelist handoff keeps it dangerous → even an auto skill must gate.
        let launcher = FakeLauncher()
        let gate = ScriptedGate([.approve])
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto),
                                launcher: launcher, resolver: KeepDangerous())
        _ = await c.run(call(), gate: gate)
        XCTAssertEqual(gate.asked, 1, "a non-whitelisted auto handoff stays foreground")
    }

    func testAutoOverBudgetEscalatesToConfirm() async {
        // Fill the cap first, then an auto call over budget must degrade to a foreground confirm.
        let budget = HandoffBudgetBox(maxCallsPerDay: 1)
        budget.record(at: t0, skillID: nil); budget.reap()   // cap is 1 → now at cap
        let launcher = FakeLauncher()
        let gate = ScriptedGate([.approve])
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto),
                                budget: budget, launcher: launcher)
        let result = await c.run(call(), gate: gate)
        XCTAssertEqual(gate.asked, 1, "auto over budget degrades to a foreground confirm, never auto-runs")
        XCTAssertEqual(result.status, .done, "the user can still approve the one extra call")
    }

    func testAutoOverBudgetInParkedSessionEscalatesNeedsYou() async {
        let budget = HandoffBudgetBox(maxCallsPerDay: 1)
        budget.record(at: t0, skillID: nil); budget.reap()
        let launcher = FakeLauncher()
        let escalation = RecordingEscalation()
        let gate = ScriptedGate([])   // never consulted in a parked session
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto),
                                budget: budget, launcher: launcher,
                                escalation: escalation, isParked: true)
        let result = await c.run(call(), gate: gate)
        XCTAssertEqual(result.status, .awaitingApproval)
        XCTAssertEqual(escalation.count, 1, "parked + over-budget escalates to needs-you")
        XCTAssertEqual(launcher.callCount, 0, "no spend / launch until the user returns")
        XCTAssertEqual(budget.snapshot().callsInLast24h(t0), 1, "no extra spend recorded")
    }

    func testAutoUnderBudgetRunsWhileParked() async {
        let launcher = FakeLauncher()
        let escalation = RecordingEscalation()
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto),
                                launcher: launcher, escalation: escalation, isParked: true)
        let result = await c.run(call(), gate: ScriptedGate([]))
        XCTAssertEqual(result.status, .done, "auto + under-budget + whitelisted runs in the background")
        XCTAssertEqual(escalation.count, 0)
        XCTAssertEqual(launcher.callCount, 1)
    }

    func testConfirmWhileParkedEscalates() async {
        let launcher = FakeLauncher()
        let escalation = RecordingEscalation()
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .confirm),
                                launcher: launcher, escalation: escalation, isParked: true)
        let result = await c.run(call(), gate: ScriptedGate([]))
        XCTAssertEqual(result.status, .awaitingApproval)
        XCTAssertEqual(escalation.count, 1)
        XCTAssertEqual(launcher.callCount, 0)
    }

    func testMissingFolderFailsCleanlyNoSpend() async {
        let launcher = FakeLauncher()
        let budget = HandoffBudgetBox(maxCallsPerDay: 5)
        // No route folder AND no skill default folder.
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto),
                                budget: budget, launcher: launcher)
        let result = await c.run(call(folder: nil), gate: ScriptedGate([.approve]))
        if case let .failed(headline) = result.status {
            XCTAssertFalse(headline.isEmpty)
        } else { XCTFail("missing folder → failed") }
        XCTAssertEqual(launcher.callCount, 0)
        XCTAssertEqual(budget.snapshot().callsInLast24h(t0), 0, "no spend on a missing-folder failure")
    }

    func testEmptyPromptLaunchesBareSession() async {
        let launcher = FakeLauncher()
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto), launcher: launcher)
        let result = await c.run(call(prompt: ""), gate: ScriptedGate([]))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(launcher.callCount, 1)
        XCTAssertEqual(launcher.calls.first?.prompt, "", "empty prompt → bare session")
    }

    func testFailedLaunchRefundsSpend() async {
        let launcher = FakeLauncher()
        launcher.throwError = HandoffError.launchFailed(headline: "Couldn't open Claude Code.", details: "boom")
        let budget = HandoffBudgetBox(maxCallsPerDay: 5)
        let audit = RecordingAudit()
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto),
                                budget: budget, launcher: launcher, audit: audit)
        let result = await c.run(call(), gate: ScriptedGate([]))
        if case let .failed(headline) = result.status {
            XCTAssertFalse(headline.contains("boom"), "raw detail never in the headline")
        } else { XCTFail("a failed launch → .failed") }
        XCTAssertEqual(budget.snapshot().callsInLast24h(t0), 0, "a launch that didn't land didn't spend")
        XCTAssertEqual(budget.snapshot().inFlight, 0)
        XCTAssertEqual(audit.records.last?.outcome, .failed(headline: "Couldn't open Claude Code."))
    }

    func testDisabledWhenCapZero() async {
        let launcher = FakeLauncher()
        let c = ClaudeHandoffContributor(
            config: ClaudeHandoffConfig(confirmMode: .auto, maxPerDay: nil),
            budget: HandoffBudgetBox(maxCallsPerDay: 0),
            launcher: launcher,
            resolver: WhitelistAuto(),
            globalDefaultPerDay: 0,   // global default also 0 → disabled
            now: { self.t0 })
        let result = await c.run(call(), gate: ScriptedGate([]))
        if case .declined = result.status {} else { XCTFail("a 0 cap → declined (disabled)") }
        XCTAssertEqual(launcher.callCount, 0)
    }

    // MARK: - Audit redaction + one-per-branch

    func testAuditNeverCarriesFullPrompt() async {
        let secretPrompt = "deploy with token=SUPERSECRETLONGVALUE12345 and also do a thing"
        let audit = RecordingAudit()
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto), audit: audit)
        _ = await c.run(call(prompt: secretPrompt), gate: ScriptedGate([]))
        XCTAssertEqual(audit.count, 1, "exactly one audit record per run")
        let summary = audit.records.first!.argumentsSummary
        XCTAssertFalse(summary.contains("SUPERSECRETLONGVALUE12345"), "the full prompt / secret is never in the summary")
        XCTAssertEqual(audit.records.first!.policy, .dangerous, "audited at the dangerous tier")
        XCTAssertEqual(audit.records.first!.tool, "launch_claude")
    }

    func testEveryBranchAuditsExactlyOnce() async {
        // done
        let a1 = RecordingAudit()
        _ = await makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto), audit: a1).run(call(), gate: ScriptedGate([]))
        XCTAssertEqual(a1.count, 1)
        // declined (skip)
        let a2 = RecordingAudit()
        _ = await makeContributor(config: ClaudeHandoffConfig(confirmMode: .confirm), audit: a2).run(call(), gate: ScriptedGate([.skip]))
        XCTAssertEqual(a2.count, 1)
        // missing folder (failed)
        let a3 = RecordingAudit()
        _ = await makeContributor(config: ClaudeHandoffConfig(confirmMode: .auto), audit: a3).run(call(folder: nil), gate: ScriptedGate([]))
        XCTAssertEqual(a3.count, 1)
    }

    func testCancelEndsQuietlyNotAFailure() async {
        let launcher = FakeLauncher()
        let c = makeContributor(config: ClaudeHandoffConfig(confirmMode: .confirm), launcher: launcher)
        let result = await c.run(call(), gate: ScriptedGate([.cancel]))
        if case let .declined(reason) = result.status {
            XCTAssertEqual(reason, TaskKindToolContributor.cancelledReason, "cancel is a quiet decline, not a failure")
        } else { XCTFail("cancel → declined(cancelled)") }
        XCTAssertEqual(launcher.callCount, 0)
    }
}
