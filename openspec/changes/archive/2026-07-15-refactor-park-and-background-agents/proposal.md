# Refactor: parked sessions survive docking, and background agents actually run

## Why

Docking (collapsing) a notch conversation while the assistant is mid-response kills the chat: the turn keeps streaming detached (by design), but the moment it settles, `ParkController.wireEngine` classifies the answered turn as a *terminal task completion* (`taskComplete: true` → row `.completed`) and immediately runs the auto-dismiss pass, which deletes `.completed` rows regardless of age — so **every chat docked mid-generation is deleted the instant its answer lands**. A second path gives the same symptom: `isTurnInFlight` excludes `.awaitingApproval`, so docking while the loop is paused on a tool approval drops the engine, orphans the suspended continuation (the response stops forever), and the idle row is reaped by the 300s countdown. Beyond the headline bug, the whole background-agent surface is spec-shaped dead code: `AgentLoop` treats a background `waitParked`/`escalate` as `continue` (the step neither runs nor suspends and the loop fabricates a completion), `ParkController.escalate`/`didAdvance` have zero callers, nothing ever transitions a session to `.parked`, `runnableSessions` has no caller, and `Subagent` is never registered as a tool.

## What Changes

- **A conversational turn settling is never terminal.** The detached settle path maps to `.idle` + unseen badge, never `.completed`. The `.completed` state and the terminal-completion instant auto-dismiss are **removed** (**BREAKING** for the `ai-parked-sessions` lifecycle spec: sessions are removed only by user deletion/purge, opt-in idle expiry, or cap eviction).
- **Expiry is opt-in and never eats unseen results.** `agentParkAutoDismissCountdown` default changes 300s → **0 = never**; a session with unseen results (badge > 0) or pending user attention is protected from idle expiry. The max-parked LRU idle eviction stays the bound.
- **Docking with a pending approval keeps the turn alive.** `isTurnInFlight` includes `.awaitingApproval`; collapse keeps the engine (and its suspended gate) detached, the row surfaces `.needsYou`, and expanding re-presents the approval card whose Approve/Skip resumes the still-suspended loop.
- **The agent loop genuinely pauses on background approvals.** A `waitParked`/`escalate` decision returns a new paused outcome (no fabricated final answer, never `taskComplete`); escalations route through `ParkController.escalate` so the needs-you badge persists and repaints.
- **A real background driver exists.** Stale `.active` rows are normalized to `.parked` + scheduled on relaunch (recovering turns lost to quit-mid-response); a coarse tick drains `runnableSessions` (one active now, K-ready seam unchanged), advances sessions on detached engines via a new `advance()` engine verb, and reports through `didAdvance`. `nextRunAt == nil` now means dormant (not runnable).
- **`Subagent` becomes a real routable tool.** A `SubagentToolContributor` registers a small built-in template set; a routed subagent step runs in a fresh conversation on the session's runtime and returns only its summary to the orchestrator thread.
- **Structured streaming + single cancellation owner.** The per-token detached `Task` spawns for `thinking` are replaced by an ordered, turn-owned stream; the production-dead `ParkLifecycleCoordinator.pending` table is removed (the engine is the single cancellation owner).
- **Tests cover the routed (registry-wired) engine paths** — the reason every one of these bugs was invisible is that the suite only exercised plain engines.

## Capabilities

### New Capabilities
- `ai-subagents`: the fixed-template, fresh-context subagent as a routable tool step — isolation contract (only the summary re-enters the orchestrator), bounded templates, no dynamic spawning.

### Modified Capabilities
- `ai-parked-sessions`: lifecycle (terminal auto-dismiss removed; expiry opt-in + unseen-protected; deletion user-initiated/expiry/eviction only), collapse contract (extends to approval-paused turns), badges (detached in-flight shows thinking; docked pending approval shows needs-you), scheduler semantics (`nextRunAt` nil = dormant; relaunch normalization + mid-turn recovery; the background driver).
- `ai-background-autonomy`: the per-step decision's parked branches genuinely pause the loop (paused outcome, no fabricated completion); escalation routes through the controller seam so needs-you persists and repaints; audit unchanged.

## Impact

- **Code**: `App/ParkController.swift` (settle classification, driver, escalate/didAdvance wiring, relaunch normalization), `AI/Parked/NotchSessionEngine.swift` (`isTurnInFlight`, `advance()`, ordered thinking stream), `AI/Parked/{ParkedSession,ParkScheduler,ParkLifecycle,ParkLifecycleCoordinator}.swift` (`.completed` removal, dormant `nextRunAt`, pending-table removal), `AI/Agent/AgentLoop.swift` (paused outcome), `AI/Audit/BackgroundToolRunner.swift` (escalation seam), new `AI/Agent/SubagentToolContributor.swift`, `Settings/AppSettings.swift` (countdown default), `App/AppCoordinator.swift` (wiring), Hub page copy for the 0 = never slider.
- **Tests**: `ParkedSessionsTests`, `ConversationSessionTests`, `BackgroundToolRunnerTests`, `BatchedRuntimeTests` (Subagent), new routed-engine and driver coverage.
- **Out of scope (deliberate)**: compute lanes / batched runtime / `ConcurrencyBudget` stay as seams (owned by `ai-compute-tiers` / `ai-batched-runtime-and-context`); `AICommandExecutor` stays one-shot; `MediaParkFeed` stays with the media change. Stored `.completed` rows from old builds are migrated (treated as `.idle`) at store load.
- **User-visible**: docked chats keep generating and keep their results; chats stop vanishing; needs-you badges survive relaunch; a quit mid-response resumes after relaunch.
