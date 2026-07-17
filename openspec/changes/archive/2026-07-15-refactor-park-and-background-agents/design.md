# Design — refactor-park-and-background-agents

## Context

The notch session machinery has two disjoint state machines coupled at exactly two points. The durable **rail row** (`ParkState`: `.active`/`.parked`/`.needsYou`/`.idle`/`.completed`, owned by `SerialParkScheduler` + `ParkedSessionStore`) and the live **engine** (`NotchSessionEngine.State`, `@MainActor`, per-session) meet only at `isTurnInFlight` (collapse decides whether to keep the engine) and `onTurnSettled` (the controller classifies the settled turn into a row state). Both couplings are wrong today:

1. `ParkController.wireEngine` (`ParkController.swift:275-288`) maps a **detached** settle with `taskComplete: true` → `.completed` → immediate `runAutoDismissPass()` → deletion. `AgentLoopOutcome.isTaskComplete` is true for every plain `.answered` turn (`AgentLoop.swift:23-33`), and production engines are always registry-wired (routed), so any chat docked mid-generation is deleted when its answer lands. The suite never sees it: every test engine is built without a registry, taking the plain path whose `taskComplete` is hard-coded `false`.
2. `isTurnInFlight` (`NotchSessionEngine.swift:121-126`) counts only `.loadingModel`/`.conversing`. Docking during `.awaitingApproval` drops the engine, orphaning the `CanvasApprovalGate`'s suspended `CheckedContinuation` — the loop's task hangs forever, the row goes `.idle`, and the 300s countdown deletes it.

The background-autonomy layer is pure, tested, and **unreachable**: `BackgroundGate`'s parked branches can never fire (rows never become `.parked` in production; a detached-streaming row stays `.active` by design), and when they *would* fire, `BackgroundToolRunner` returns `.awaitingApproval` without suspending and `AgentLoop` treats that status as `continue` (`AgentLoop.swift:152-154`) — the step neither runs nor waits, and the loop synthesizes a final answer. `ParkController.escalate`/`didAdvance` (the persist+repaint seams) have zero callers; `runnableSessions` has no caller; `ParkLifecycleCoordinator`'s `pending` cancellation table is only ever populated by tests; `Subagent` is a complete type registered nowhere; `runRoutedTurn`'s `onThinking` spawns an unordered, uncancellable detached `Task` per token.

Constraints: everything here is MLX-free Core (`swift build`/`swift test`); the scheduler seam's shapes are pinned (K-ready, consumed by `ai-batched-runtime-and-context`); `AICommandExecutor` stays one-shot; compute lanes/`ConcurrencyBudget`/`MediaParkFeed` belong to other in-flight changes.

## Goals / Non-Goals

**Goals:**
- Docking mid-response (streaming OR paused on approval) never stops the turn and never deletes the session.
- Session removal is exclusively: user delete/purge, **opt-in** idle expiry (default off, unseen-protected), or max-parked LRU idle eviction.
- The parked branches of the background policy actually work end-to-end: pause the loop honestly, escalate through the controller so needs-you persists + repaints, advance runnable sessions via a real driver, recover quit-mid-turn sessions on relaunch.
- `Subagent` is reachable: a routed tool step that runs in a fresh conversation and returns only a summary.
- The routed engine path is test-covered.

**Non-Goals:**
- No batched K>1 advancement (the driver requests one slot; the seam already supports K).
- No compute-lane wiring, no `MediaParkFeed`, no `AICommandExecutor` changes.
- No durable persistence of a pending `TaskReview` (an approval interrupted by app quit re-presents restore-era style: the next turn's loop re-reaches it).
- No mid-stream partial-text persistence (a crash mid-turn loses only the partial; relaunch recovery re-runs the turn).
- No dynamic/model-invented subagents; templates are a small built-in set.

## Decisions

### D1 — A settled chat turn is never terminal: retire `.completed`
`onTurnSettled` loses its `taskComplete` parameter (with `AgentLoopOutcome.isTaskComplete` demoted to an internal detail of the loop). Detached settle → `.idle` + badge increment; expanded settle → `.active` + badge 0. The `.completed` case is removed from `ParkState`; `ParkLifecycle.dismissable` no longer has a terminal clause; `ParkController.didAdvance` drops its `taskComplete` parameter and terminal flow. Store load migrates a decoded `.completed` row to `.idle` (custom `Decodable` on the raw value) so old disk state deserializes.
*Alternative considered*: keep `.completed` for future fire-and-forget task sessions — rejected: nothing produces it after this change, and dead states in a lifecycle enum are exactly how this bug happened.

### D2 — Expiry is opt-in and protects unseen work
`Defaults.agentParkAutoDismissCountdown` 300 → **0**, meaning **never expire** (`ParkLifecycle` treats `countdown <= 0` as no-expiry). When a user sets a positive countdown, `dismissable` requires: state `.idle` (never `.active`/`.needsYou`/`.parked`), `badgeCount == 0` (unseen results protect), and age > countdown. Eviction (`maxParked`, LRU `.idle`) is unchanged — it remains the bound, and user-initiated pressure (spamming new chats) may still evict an unseen idle row; that is the documented soft-cap trade-off. Hub copy for the countdown slider gains a "0 = never" label.
*Alternative*: keep 300s default but protect unseen — rejected: a docked chat the user has read still vanishing after 5 minutes is the complained-about behavior, not a defensible default for a chat surface.

### D3 — `.awaitingApproval` is in-flight; docking a paused approval surfaces `.needsYou`
`isTurnInFlight` includes `.awaitingApproval`. Collapse of a paused session keeps the engine detached (gate continuation intact) and sets the row `.needsYou` (it is blocked on the user regardless of tier — the step is already at the foreground gate). `expand` already reuses a detached in-flight engine without rebinding (`ParkController.swift:121`), so the panel re-renders `.awaitingApproval`'s card and Approve/Skip resolves the original continuation; the loop then continues (detached again if the user re-docks — the settle callback re-classifies). Collapse of a *streaming* session keeps today's `.active` row (structural exclusion from the runnable set); the rail derives its **thinking** badge from "`.active` and not expanded" via the existing `sessionsProvider`/`engineProvider` seams.
*Alternative*: a dedicated `.thinking` `ParkState` — rejected: it duplicates engine state into the durable row and creates a second normalization problem on relaunch.

### D4 — `nextRunAt` gains meaning: nil = dormant; relaunch normalizes stale rows
`runnableSessions` requires `state == .parked && nextRunAt != nil && nextRunAt <= now` (today nil is treated as runnable-now; nothing observes the difference because nothing calls it). At `ParkController` init, rows are **normalized**: `.active` (a quit mid-turn or mid-read — no engine can exist at launch) → `.parked` with `nextRunAt = now` when the conversation's last message is a user/tool message awaiting an assistant reply, else `.idle`; `.needsYou` stays `.needsYou` (blocked on user, not runnable). This turns today's forever-protected zombie `.active` rows into recovered turns.

### D5 — A real driver: `advance()` on detached engines, one active now
`NotchSessionEngine` gains `advance()`: guard a conversation is bound and its last message is not an assistant answer, then run the existing turn machinery **without appending a user message** (the routed path when registry-wired). `ParkController` gains `runAdvancePass(now:)`, called from the existing coarse 60s timer tick in `AppCoordinator` (plus once after init normalization): it requests `parkScheduler.runnableSessions(now:, maxSlots: 1)`, skips entirely if any engine `isTurnInFlight` (the foreground/detached turn owns the single slot — the scheduler seam's "foreground always served" contract), rebuilds an engine from the stored conversation (`bind` + `wireEngine`), marks the row advancing (`nextRunAt = nil` so a second tick can't double-serve it), and calls `advance()`. Settlement flows through the same `onTurnSettled` classification as any detached turn (`.idle` + badge). A `.failed` advance routes through `didAdvance` (now actually called), which re-parks with the scheduler's backoff.
*Alternative*: a per-session `Task` queue owned by the scheduler — rejected: the engine already owns turn execution, cancellation, and settlement; the driver only needs to pick sessions and hand them engines.

### D6 — The loop pauses honestly: a `.pausedAwaitingUser` outcome
`AgentLoopOutcome` gains `.pausedAwaitingUser` (not task-complete, carries no fabricated text). In `AgentLoop.run`, a step result whose status is `.awaitingApproval` **returns** with that outcome instead of `continue` — on the foreground path this status can only come from the background runner (the foreground gate resolves inside the contributor await, yielding `.done`/`.declined`), so foreground behavior is unchanged. `BackgroundToolRunner` gains an `onEscalate` callback (injected by the app as `{ parkController.escalate($0, reason: $1) }`) replacing the raw `scheduler` reference, so escalation persists + repaints; `waitParked` keeps the row `.parked` and dormant (`nextRunAt = nil`) via the settle path. `NotchSessionEngine.runRoutedTurn` maps `.pausedAwaitingUser` to a settled turn (steps recorded, no assistant message appended, state `.awaitingTurn`) so the snapshot persists; the row classification (needs-you for escalate, dormant parked for wait) rides the settle callback plus the escalation callback. Approval-after-expand re-presents restore-era style (Non-Goal: no durable `TaskReview`).

### D7 — Ordered, turn-owned thinking stream
`runRoutedTurn` builds an `AsyncStream<String>`; `onThinking` becomes `{ continuation.yield($0) }` and a consumer task (child of the turn, started before `loop.run`, awaited after, continuation finished on all exits) appends to `self.thinking` on the main actor. Tokens are ordered, and cancelling `generationTask` cancels the consumer with the turn — no more per-token detached `Task`s racing settlement.

### D8 — Single cancellation owner: the engine
`ParkLifecycleCoordinator.pending`/`registerPending`/its discard-cancel are deleted (production-dead). `ParkController.discard` already cancels via `engines[id]?.cancelAll()`; that stays the one cancellation path. Tests asserting `registerPending` move to engine-based cancellation assertions.

### D9 — Subagents: a contributor over built-in templates
New `SubagentToolContributor` (MLX-free Core): holds `[Subagent]` (built-ins: `summarize` — condense provided input; `draft` — compose a longer text from a brief; both `maxTurns: 1` in v1) and a `runtimeProvider: () async throws -> LLMRuntime` (app-side: `{ try await modelManager.runtime(requiring: [.text]) }`). Each template contributes its `toolDescriptor` (`.auto`, CONTAINED — read-only to the orchestrator's world); `run` builds `freshConversation(input:)`, streams one chat over it, and returns a `.done` `ToolStepResult` whose summary is the subagent's response — only the summary re-enters the orchestrator context (the loop's existing `.tool` message append). Registered in `AppCoordinator`'s `ToolRegistry` alongside the existing contributors; audited like any step by the runner. v1 deliberately runs no tools inside the subagent (no recursion).
*Alternative*: skills-as-subagents — deferred; the contributor's template set is injectable, so a skills-derived set is a later drop-in.

### D10 — Routed-path test coverage
New tests build engines **with** a registry/candidate source over `StubLLMRuntime`: dock-mid-routed-turn settles `.idle`+badge and survives the auto-dismiss pass (the headline regression); dock-during-approval keeps the engine, shows `.needsYou`, approve-after-expand resumes; relaunch normalization + `runAdvancePass` recovers a mid-turn row end-to-end; loop pauses on runner `waitParked`/`escalate` (no fabricated answer); escalation persists through `ParkController.escalate`; expiry honors 0=never/unseen-protection; thinking tokens arrive in order and cancel with the turn; a routed `subagent:summarize` step returns only the summary.

## Risks / Trade-offs

- **[Re-running a recovered turn re-executes auto tool steps]** → Accepted (restore-era convention, audited); recovery only triggers when the last message awaits an assistant reply, and dangerous/confirm steps still gate.
- **[Removing `.completed` breaks old persisted rows]** → decode-time migration maps the raw value to `.idle`; store tests cover the old JSON shape.
- **[Unseen-protected expiry can accumulate rows]** → the max-parked cap (LRU idle eviction) remains the hard bound; eviction deliberately ignores badge protection.
- **[Driver double-advance races]** → single slot + `isTurnInFlight` short-circuit + `nextRunAt = nil` on serve; the scheduler stays the only runnable-set authority.
- **[`.needsYou` on a docked confirm-tier approval is stronger than the autonomy spec's "waits parked without escalating"]** → scoped: that clause governs steps *encountered while parked* (runner `waitParked`, which stays dormant-parked); a step already at the **foreground gate** when the user docks is user-blocking by construction, so needs-you is the honest badge.
- **[Subagent adds a second in-flight generation surface]** → v1 subagent runs inside the orchestrator's turn (same `generationTask`, same cancellation), single-turn, no tools — no new concurrency.

## Migration Plan

Single change, all Core: land types (`ParkState` minus `.completed` + migration, loop outcome, engine verbs), then controller/driver wiring, then subagent contributor, then tests; `swift build` + `swift test` throughout; user run-verifies the live notch behavior (dock mid-response, approval round-trip, relaunch recovery) on a stable-signed build. Rollback is a straight revert (no data format change other than the tolerated `.completed` decode).

## Open Questions

None blocking. (Subagent template set may grow via skills later; K>1 advancement arrives with the batched-runtime change on the unchanged seam.)
