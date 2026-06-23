> Decomposed for a workflow fan-out: §1 is the type substrate (do first), §2 the budget gate, §3 the launcher adapter, §4 the contributor state machine (depends on §1–§3), §5 the cross-slice seams, §6 errors, §7 verifies. Every item is MLX-free Core verified by `swift test` unless noted; NO `.app` build, NO signing.

## 1. Handoff config types (pure Core type substrate)

- [x] 1.1 `HandoffConfirmMode` (`confirm`/`auto`) + `ClaudeHandoffConfig` already on disk at `AI/Skills/ClaudeHandoffConfig.swift` (defined by skills-as-files, OWNED by this slice). CONSUMED verbatim per SCOPE (do not redefine). Its shape is `{confirmMode, folder, startingPrompt, maxPerDay}`; `confirmMode` defaults to `.confirm`. *Verify: `swift test` `ClaudeHandoffTests.testConfigDefaultsToConfirm` — default == confirm + Codable round-trip.*
- [x] 1.2 Doc-comment in the existing type already states it is the SAME type carried on `SkillManifest.claudeHandoff` (single definition in Core). *Verified against the on-disk file header.*

## 2. Budget / rate cap (pure, `now:`-injected)

- [x] 2.1 Added `AI/Handoff/HandoffBudget.swift`: `HandoffSpend{at, skillID}`, `HandoffBudget{maxCallsPerDay, maxConcurrent, ledger, inFlight}` with PURE `allows(now:)`, `record(at:skillID:)`, `reap()`, `refund(at:)`. `now` is an INPUT. *Verify: `swift test` — `testBudgetAllowsUnderCapBlocksAtCap`, `testBudgetConcurrencyBlocks`, `testBudgetRefundRestoresSlot`, `testBudgetRollingWindowNotCalendarDay`.*
- [x] 2.2 Rolling-24h, not calendar-day. *Verify: `swift test` `testBudgetMidnightCannotBeGamed` — two `now`s straddling midnight count together, no reset.*
- [x] 2.3 Ledger persistence seam: `HandoffLedgerStore` (+ `InMemoryHandoffLedgerStore` / `DiskHandoffLedgerStore` under Application Support); `HandoffBudgetBox` seeds the ledger from the store at init + re-saves on record/refund. *Verify: `swift test` `testBudgetPersistsAcrossReload` — a fresh box over the same store still counts prior spends in the window.*

## 3. Production launcher (the open-claude-here adapter)

- [x] 3.1 Added `AI/Handoff/HandoffLauncher.swift`: the `HandoffLauncher` protocol + `OpenClaudeHandoffLauncher` composing `ClaudeLauncher.shellQuote`/`writeCommandFile`/`resolveClaudePath` + `NSWorkspace.shared.open` (off-main write, main-actor open, success-needs-no-notification). Non-empty prompt → `claude '<prompt>'`; empty → bare `claude`. `Launcher/ClaudeLaunch.swift` UNCHANGED. *Verify: `swift test` `testInnerCommandEmptyVsNonEmpty`; the real spawn is **user-build** only.*
- [x] 3.2 `ClaudeLaunchError` → `HandoffError.launchFailed` mapped at the launch boundary (`OpenClaudeHandoffLauncher.map`). *Verify: `swift test` `testLaunchErrorMapping` — clean headline through, raw text only in details.*

## 4. The contributor — `launch_claude` tool + cost-gate state machine

- [x] 4.1 Added `AI/Handoff/ClaudeHandoffContributor.swift` `descriptors()`: a single `ToolDescriptor{name:"launch_claude", argsSchema:{folder?, prompt}, writePolicy:.dangerous, keywords}` — ALWAYS `.dangerous`. `canHandle("launch_claude") == true`. *Verify: `swift test` `testDescriptorIsAlwaysDangerous`, `testCanHandle`.*
- [x] 4.2 `effectiveGate()`: 0 resolved cap → `.disabled`; resolver intersects `.dangerous` ∩ whitelist FIRST (non-whitelisted stays foreground regardless of skill auto); `!budget.allows(now)` → `.overBudget`; else `.auto`→`.autoRun`, `.confirm`→`.needsApproval`. (NB: the on-disk `ClaudeHandoffConfig` has no `enabled` field; "disabled" is modeled as a resolved cap of 0 — global default 0 → declined.) *Verify: `swift test` `testAutoSkillUnderBudgetRunsWithoutGate`, `testAutoSkillRequiresWhitelistToRunUnprompted`, `testDisabledWhenCapZero`.*
- [x] 4.3 `run(_:gate:)` state machine: `.autoRun`→record+audit+launch→`.done` (throw→`.failed`+refund); `.needsApproval`→await gate (approve→launch, skip→`.declined("skipped")` no spend, cancel→quiet loop end); `.overBudget`→degrade to confirm (active) / escalate needs-you (parked); `.disabled`→`.declined`. *Verify: `swift test` `testConfirmSkillGatesAndApprovesLaunchesOnce`, `testConfirmSkillSkipDoesNotSpendOrLaunch`, `testAutoOverBudgetEscalatesToConfirm`, `testCancelEndsQuietlyNotAFailure`.*
- [x] 4.4 Folder resolution: route `folder` → else `config.folder` → else `.failed(HandoffError.missingFolder)`, no spend. Empty prompt allowed (bare session). *Verify: `swift test` `testMissingFolderFailsCleanlyNoSpend`, `testEmptyPromptLaunchesBareSession`.*
- [x] 4.5 Refund-on-throw invariant. *Verify: `swift test` `testFailedLaunchRefundsSpend` — failed launch leaves the budget unchanged + `inFlight == 0`.*

## 5. Cross-slice seams (compile-in-isolation today, bind later)

- [x] 5.1 Added `AI/Handoff/HandoffSeams.swift`: `HandoffAuditing` (+ `NoopHandoffAudit` / `AuditLogHandoffAuditing` bridging the real `AuditLog`) + `HandoffEscalating` (+ `NoopHandoffEscalation` / `ParkSchedulerHandoffEscalation` bridging the real `ParkScheduler.escalate`). NB: `ai-background-autonomy` + `ai-parked-sessions` ARE on disk (the design's "not yet on disk" note is stale), so the production bridges are wired to the real types now, not deferred. *Verify: `swift test` with recording doubles.*
- [x] 5.2 One `AuditRecord{sessionID, tool:"launch_claude", policy:.dangerous, argumentsSummary: folder + truncated prompt (via `AuditRedaction`), outcome, wasBackground, timestamp}` per `run`, all branches. *Verify: `swift test` `testAuditNeverCarriesFullPrompt`, `testEveryBranchAuditsExactlyOnce` — exactly one record per run, no full prompt/secret in the summary.*
- [x] 5.3 Parked escalation: a `.needsApproval`/`.overBudget` handoff while parked routes to `escalation.escalate(...)` (needs-you, `.awaitingApproval`, no spend); `.autoRun` under budget runs in the background, still audited. *Verify: `swift test` `testConfirmWhileParkedEscalates`, `testAutoOverBudgetInParkedSessionEscalatesNeedsYou`, `testAutoUnderBudgetRunsWhileParked`.*

## 6. Errors — one taxonomy, one translator

- [x] 6.1 Added `AI/Handoff/HandoffError.swift`: `HandoffError` (`disabled`/`overBudgetNoUser`/`missingFolder`/`launchFailed(headline, details)`), `LocalizedError` with clean per-case `errorDescription`; raw text only in `copyableDetails`/logs. Extended `AIError.message(for:)` with a `HandoffError` branch (THE one translator). *Verify: `swift test` `testHandoffErrorTranslatorCleanHeadlines`, `testLaunchErrorMapping`.*
- [x] 6.2 A failed/over-budget handoff is an observable `ToolStepResult(.failed/.declined)` — never a false Done, never silence, never `NSAlert`; cancel is not a failure. *Verify: `swift test` `testFailedLaunchRefundsSpend`, `testCancelEndsQuietlyNotAFailure`.*

## 7. Verify

- [x] 7.1 `swift build --target ThreeFingerSwitcherCore` + `swift test` green (1230 tests, 0 failures; 27 in `ClaudeHandoffTests`) — config, budget, launcher mapping, contributor state machine, audit redaction, parked escalation all covered with fake launcher + scripted gate + recording audit/escalation. *Verify: `swift test`.*
- [x] 7.2 `Launcher/ClaudeLaunch.swift` / `Launcher/LaunchService.swift` UNMODIFIED. *Verify: `git diff --stat` shows no changes to those files.*
- [x] 7.3 `openspec validate ai-claude-handoff --strict` passes. *Verify below.*
- [x] 7.4 No `.app` build, no signing, no permission change — `swift test` only; the real `claude` spawn is exercised by the user's stable-signed build. *Verified.*
- [ ] 7.5 **User run-verify** (later, after the router + canvas + autonomy land, in a stable-signed build): a conversational ask that exceeds the local model routes to `launch_claude`; a default-confirm handoff waits for a DOWN approve / RIGHT skip and opens Claude in the folder with the prompt; an `auto` skill under budget opens Claude without a prompt; over the daily cap an `auto` handoff degrades to a foreground confirm (never silent); a parked session shows a needs-you badge for a pending dangerous handoff; the audit log shows every handoff attempt. *(Deferred — depends on downstream slices.)*
