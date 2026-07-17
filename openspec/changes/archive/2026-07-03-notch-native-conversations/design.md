## Context

The V2 wave routed every AI-band fire through `AICommandExecutor.fireConversational(_:)` (two call sites in `AppCoordinator`), which opens a typed multi-turn thread on the launcher canvas; the v1 one-shot machine (`fire(_:)` → `.streaming` → `.ready` → `commit()`) is still fully present in the executor and the canvas view renders both paths (it branches on `executor.conversation != nil`). The notch dock is live and committed (5a85e4b): `ParkController` owns `ParkedSessionStore` + `SerialParkScheduler` + `ParkLifecycleCoordinator`; `NotchHomeZoneController` owns the cursor-reveal rail on a non-activating `SwitcherPanel` that merges black-on-black with the physical notch (tab degradation on notchless displays). Conversations reach the dock only by overscroll-parking the canvas, and leave it only by restoring back onto the canvas.

The synced `ai-command-band` spec still describes the v1 grammar (the conversational delta was archived **unsynced**), and the `ai-parked-sessions` spec was just synced as-built. This change makes the code match the first and re-draws the second.

Constraints: the working tree carries a concurrent wave's uncommitted work in some of the same files (`AICommandExecutor.swift`, `AICommandCanvasView.swift`, `ParkController.swift`) — edits must be surgical, on top of current tree state, never a file-wide rewrite. Core stays MLX-free; all conversation logic must verify under `swift test` with `StubLLMRuntime`; overlay work is `xcodebuild` compile-verify + user run-verify.

## Goals / Non-Goals

**Goals:**

- Quick actions are the v1 one-shot grammar again: auto-fire, stream, DOWN-commit/RIGHT-discard, ephemeral. No thread, no session, no rail card — ever.
- Conversations are notch-exclusive: born from the rail's "+ New chat" card, operated in an in-place expanded notch panel, backgrounded by collapse, gone only via expiry or deletion.
- The multi-turn engine survives the revert intact (re-homed, not rebuilt): streaming turns, thinking channel, tool routing with approval, badges/escalation/auto-dismiss.
- The scheduler/store/lifecycle seams stay signature-stable so the batched-runtime / background-autonomy / media waves keep plugging in unchanged.

**Non-Goals:**

- No composer attachments UI at the notch (the engine keeps `send(_:images:)`; UI is a documented future).
- No launcher→notch bridge of any kind (no "continue in notch" affordance on the one-shot canvas).
- No K-slot scheduling changes, no store schema changes, no new permissions, no gesture-recognizer changes.
- No visual redesign of the merged-notch chrome (the 5a85e4b look is kept; the expanded panel extends it).

## Decisions

### D1 — Extract a `NotchSessionEngine`; do NOT share the executor between surfaces

The conversation machine moves from `AICommandExecutor` into a new `NotchSessionEngine` (Core, `AI/Parked/`). Alternatives rejected:

- *Bind the notch panel to the existing executor*: `fire(_:)` begins with `cancel()` + `conversation = nil` — any quick action would kill the open notch conversation. The two surfaces have independent lifecycles; sharing one stateful object couples them wrongly.
- *A second `AICommandExecutor` instance for the notch*: drags dead weight (input acquisition, output routing, language persistence, availability canvas states) and keeps two copies of the fire machinery alive.

The engine owns: one bound `AgentConversation`, the streaming turn loop (`runTurn` moved wholesale: ChatTemplate build, thinking/response channels, cancellation-is-not-failure), `send(_:images:)`/`continueConversation`, the `CanvasApprovalGate` seams (`makeApprovalGate`/`approve`/`skip`), `toolSteps`, and pending attachments (API only). Its state enum is the conversational subset: `.idle`, `.unavailable`, `.loadingModel`, `.conversing(partial)`, `.awaitingTurn`, `.awaitingApproval(TaskReview)`, `.failed(message)`. It takes the same injected deps the executor's conversational half used (`ModelManager`, `TaskDispatching`, tool registry/candidate source/skill tools, optional `BackgroundToolRunner`, `reasoning`), so `AppCoordinator` wires it from parts it already has.

Dropped in the move (canvas-era concepts with no notch meaning): seed acquisition + `SeedKind` + `BareSeedDefault` + `pendingSeed*` (a notch session starts from typing; turn 1 is the first typed message), `conversationOutput` + `extractLatest` (no front-app output target from the notch — a **Copy** button on assistant turns replaces extraction), `canvasAtTop`/`canvasAtBottom` + park/restore transitions.

### D2 — The executor reverts to exactly the v1 surface

`fire(_:)`/`run`/`commit`/`cancel`/availability/language/`.reviewingAction` armed-confirm stay; everything conversational is deleted (not deprecated — the engine is the one home). State enum returns to: `.idle`, `.loadingModel`, `.noInput`, `.streaming`, `.ready`, `.reviewingAction`, `.declined`, `.failed`, `.unavailable`, `.committed`. `onPark`/`onTaskComplete` seams are removed. Rationale for delete-over-flag: the synced spec is v1; keeping dead conversational cases invites the drift this pivot exists to end.

### D3 — Sessions are born durable, at the notch

"+ New chat" (a persistent rail card) creates an `AgentConversation` (title "New chat" until the first turn names it), upserts it to the store immediately, and expands it. Rationale: "it stays there until expiry or deletion" — a session must survive relaunch from birth, so birth = store upsert, not a foreground-only object later handed off. `ParkController` grows the session verbs (`newSession()`, `expand(id:)`, `collapse()`, existing `discard(_:)`) and loses the canvas handoff (`park(conversation:)` becomes the internal upsert used by birth/collapse; `onRestoreConversation` is deleted).

One foreground engine at a time (matching the one-active-now scheduler): expanding a card binds the engine to that stored conversation (`.awaitingTurn`, or `.awaitingApproval` if the session escalated); expanding another card first collapses the current one. Collapse persists the conversation back to the store, unbinds the engine **without cancelling an in-flight turn** (the turn's completion writes through to the store/scheduler exactly as a background advance does), and returns the panel to rail mode. Discard of the expanded session cancels via the existing authoritative path.

### D4 — The expanded panel is the SAME notch panel, mode-switched — and it pins the reveal

`NotchHomeZoneViewModel` gains a `mode: .rail | .expanded(AgentSessionID)`; the overlay renders the conversation view (thread + composer + tool-step list + approval card + failed card) inside the same merged-notch chrome, sized by a new `NotchHomeZoneLayout.solveExpanded(visibleFrame:)` (wider/taller clamp fractions; content scrolls). Alternatives rejected: a second panel (two top-center panels fight over z-order and double the teardown landmines); reusing the launcher canvas panel (that is the surface being vacated).

While `.expanded`: the controller **stops feeding `NotchRevealModel` dismiss decisions** (cursor-leave and grace-dismiss must not tear down an open conversation; the reveal model itself is untouched — the controller simply short-circuits, mirroring `menuSuppressedPID`'s consumer-side suppression precedent). Collapse paths: the header's collapse chevron, `Esc` in the composer, clicking the notch nub. Teardown/collapse ordering keeps the synchronous `orderOut` discipline for feature-off/Space-switch (the ghost-on-Space-switch landmine).

### D5 — Key-window flip on the composer, non-activating otherwise

The notch panel keeps `[.borderless, .nonactivatingPanel]` and never becomes main. While the composer field is focused, the panel sets `SwitcherPanel.keyInteractive = true` + `makeKey()` so keystrokes reach the field (the launcher canvas precedent, `LauncherOverlayController.setCanvasInteractive`); on collapse/blur it drops key and the previously-front app keeps focus (nothing was activated). Approve/Skip and Copy are mouse buttons — the notch is the cursor-and-keyboard world; the two-finger compass grammar stays a launcher-surface concept and is NOT imported here.

### D6 — Terminal and lifecycle semantics are inherited, not re-invented

Expiry = the existing `ParkLifecycle` auto-dismiss countdown pass (terminal `.completed` rows immediately, idle-past-countdown rows on the timer) — unchanged. Deletion = the existing authoritative `discard(_:)` (cancel pending, remove durable row; completed side effects are never rolled back) — reachable from the card's context menu and the expanded header. A foreground engine turn that completes a task reports through the engine's `onTaskComplete` → `ParkController.didAdvance(taskComplete:)` so the terminal auto-dismiss applies to foreground completions too. Needs-you: escalation still lights the glow; expanding the escalated card presents the approval card, and resolving it clears the badge/glow through the existing republish.

## Risks / Trade-offs

- **[Concurrent-wave collisions]** The fleet/media wave has uncommitted edits in `AICommandExecutor.swift` / `AICommandCanvasView.swift` / `ParkController.swift`. → Mitigation: surgical edits on current tree state only; never revert-by-checkout, never rewrite whole files; `swift build` after each file to catch interface drift early.
- **[Key-flip focus leaks]** A non-activating panel holding key while collapsing on a Space switch could strand first-responder state. → Mitigation: drop key **before** the synchronous `orderOut` on every collapse path (the Bug-4 ordering lesson from the rail-restore work, inverted); compile-verified + explicit user run-verify item.
- **[Losing extraction entirely]** v1's DOWN-commit applied results into the front app; notch answers only offer Copy. That is a deliberate capability narrowing at the notch (the quick-action band is the "write into the app" surface). → Documented in the spec delta so it reads as intent, not omission.
- **[Test re-homing breadth]** `ConversationSessionTests`/`ConversationalCanvasTests`/parts of `AICommandExecutorTests`+`BatchedRuntimeTests` drive executor conversations. → Mitigation: the engine keeps method names/shapes (`send`, `continueConversation`, `approve`, `skip`, `toolSteps`) so re-targeting is mostly a subject swap; park/restore/seed cases are deleted with their behavior, new expand/collapse/expire cases added.
- **[Rail discoverability of "+ New chat"]** An empty dock previously had nothing to reveal for; now the reveal always has at least the new-chat card. Slight behavior change to the empty-rail reveal → covered by a scenario.

## Migration Plan

Code-only pivot; no data migration (the store schema is untouched; existing parked rows simply render on the rail and expand in place). Bookkeeping already done ahead of this change: `ai-parked-sessions` archived **with** sync (base spec now in `openspec/specs/`), `ai-conversational-canvas` archived **without** sync (its delta described the behavior being reverted). Rollback = revert the change's commits; the store remains readable either way.

## Open Questions

_None blocking._ Composer attachments at the notch and any future launcher→notch affordance are explicitly deferred (Non-Goals).
