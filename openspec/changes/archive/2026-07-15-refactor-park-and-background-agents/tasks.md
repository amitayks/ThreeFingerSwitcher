# Tasks — refactor-park-and-background-agents

## 1. Lifecycle types: retire `.completed`, dormant `nextRunAt`, expiry semantics (D1, D2, D4)

- [x] 1.1 Remove `.completed` from `ParkState`; add decode-time migration (old raw value → `.idle`) so persisted rows from older builds load; update `isTerminal`/`isProtectedFromAging` accordingly
- [x] 1.2 `ParkLifecycle`: drop the terminal-dismiss clause; `dismissable` requires `.idle` + `badgeCount == 0` + age > countdown, and `countdown <= 0` disables expiry entirely
- [x] 1.3 `SerialParkScheduler.runnableSessions`: require `nextRunAt != nil && nextRunAt <= now` (nil = dormant); keep ordering + slot honoring; `didAdvance` failure path sets a scheduled retry `nextRunAt`
- [x] 1.4 `AppSettings`: `Defaults.agentParkAutoDismissCountdown` 300 → 0; Hub slider copy gains "0 = never"
- [x] 1.5 Update `ParkedSessionsTests` for the new lifecycle table (no terminal dismiss; unseen-badge protection; 0 = never; dormant rows not runnable; old `.completed` JSON decodes as `.idle`)

## 2. Engine: in-flight includes approval, `advance()`, ordered thinking (D3, D5, D7)

- [x] 2.1 `NotchSessionEngine.isTurnInFlight` includes `.awaitingApproval`; verify `unbind()`/`expand` reuse keeps the suspended gate alive across a dock/expand round-trip
- [x] 2.2 Add `NotchSessionEngine.advance()`: guard bound conversation whose last message awaits an assistant reply, then run the existing turn machinery without appending a user message
- [x] 2.3 Replace `runRoutedTurn`'s per-token `Task { @MainActor }` `onThinking` with an `AsyncStream` consumer owned by the turn (ordered, finished on all exits, cancelled with `generationTask`)
- [x] 2.4 `onTurnSettled` drops the `taskComplete` parameter (replaced by a `TurnSettlement` enum: answered / pausedAwaitingUser / failed — plus `onApprovalPending` so an approval arising AFTER a dock surfaces needs-you instead of pausing invisibly)
- [x] 2.5 `ConversationSessionTests`: routed-engine coverage (registry + candidate source over a scripted routing runtime) — settle, advance(), thinking ordering, approval round-trip survival

## 3. Loop + runner: honest pause, controller-routed escalation (D6)

- [x] 3.1 `AgentLoopOutcome` gains `.pausedAwaitingUser` (never task-complete, no fabricated text); `AgentLoop.run` returns it when a step result is `.awaitingApproval` instead of `continue`
- [x] 3.2 `BackgroundToolRunner`: replace the raw `scheduler` reference with an injected `onEscalate` callback; `waitParked` result unchanged (the loop now pauses on it)
- [x] 3.3 `NotchSessionEngine.runRoutedTurn` maps `.pausedAwaitingUser` to a settled turn (steps recorded, no assistant message, no failure)
- [x] 3.4 `BackgroundToolRunnerTests` + loop tests: waitParked/escalate through the FULL loop pause with no fabricated answer; escalation reaches the callback; foreground path unchanged

## 4. Controller: settle classification, needs-you dock, driver, normalization (D1, D3, D4, D5, D8)

- [x] 4.1 `wireEngine` settle: expanded → `.active` + badge 0; detached-answered → `.idle` + badge increment — no `.completed`, no auto-dismiss call; detached-paused keeps needs-you/dormant-parked; detached-failed reports through `didAdvance` (scheduled retry)
- [x] 4.2 `collapseCurrentIfNeeded`: a paused-at-approval engine is kept detached and its row set `.needsYou`; a streaming engine keeps today's `.active` row; rail badge distinguishes scheduled/advancing `.parked` ("Thinking…") from dormant ("Waiting for you")
- [x] 4.3 `ParkController.escalate` wired as the runner's `onEscalate` (persist + repaint); `didAdvance` drops `taskComplete` and is called by the settle failure path
- [x] 4.4 Init-time normalization: `.active` rows → `.parked` + `nextRunAt = now` when the conversation awaits an assistant reply, else `.idle`; `.needsYou` preserved
- [x] 4.5 `runAdvancePass(now:)`: skip while any engine is GENERATING (a gate-suspended engine never blocks the slot); serve `runnableSessions(now:, maxSlots: 1)`; bind + wire a detached engine; `advance()`; dormant-clear when the advance can't start; wired into `AppCoordinator`'s 60s maintenance tick + once post-launch
- [x] 4.6 Remove `ParkLifecycleCoordinator.pending`/`registerPending` (engine = single cancellation owner); migrate the tests that used it
- [x] 4.7 `ParkedSessionsTests`: end-to-end regressions — dock-mid-routed-turn survives settle + dismiss pass; dock-at-approval → needs-you → expand → approve resumes; relaunch normalization + driver recovery; driver never double-serves

## 5. Subagents (D9)

- [x] 5.1 New `SubagentToolContributor` (AI/Agent/): injectable `[Subagent]` (built-ins `summarize`, `draft`), `runtimeProvider`, descriptors via `toolDescriptor`, run = one chat over `freshConversation(input:)` → `.done` summary; failures map to clean failed steps; no subagent tools offered inside a subagent
- [x] 5.2 Register in `AppCoordinator`'s `ToolRegistry` with `runtimeProvider = modelManager.runtime(requiring: [.text])`
- [x] 5.3 Tests: routed `subagent:summarize` step over a stub runtime — fresh-context isolation, summary-only re-entry, cancellation with the turn, failure = clean failed step

## 6. Verify

- [x] 6.1 `swift build` + `swift test` green (MLX-free Core — 1548 tests, 0 failures)
- [x] 6.2 `xcodebuild` compile-verify the app target (no install/launch — exit 0, no errors)
- [ ] 6.3 User run-verify on a stable-signed build (`INSTALL=1 ./scripts/build-app.sh`): dock mid-response (answer lands, badge, chat persists), dock at approval (needs-you round-trip), quit mid-turn → relaunch recovery — PENDING the user's own Terminal (the agent shell cannot sign/install/launch)
