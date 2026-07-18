# Design: model-idle-ttl-and-memory-pressure

## Context

`ModelManager` (`Sources/ThreeFingerSwitcher/AI/ModelManager.swift`, `@MainActor`) owns the resident runtime. Loading is lazy and single-flighted (`coalescedLoad`); `evict()` exists and is correct, but is only reachable from three manual/plan-driven call sites. The spec's lifecycle requirement already *states* "evicted on memory pressure" — unimplemented. The parked-sessions machinery (`NotchSessionEngine`, the background driver's coarse tick, the single-generation-slot scheduler) knows when the AI system is busy; `ModelManager` today has no view of that.

Established idioms this design leans on (all already in the codebase):

- **Injected closures for environment probes** — `hardwareSupports`, `fleetFreeBytes`, `provisionedOnDisk` are injected into `ModelManager` so Core tests fake them. The pressure source and quiescence signal follow the same shape.
- **Pure policy, time as an input** — `ResidencyPlanner`, `ConcurrencyBudget`, and the role-to-lane policy are pure functions; `DockHoverModel.feed(now:)` takes timestamps. The eviction decision becomes a pure `EvictionPolicy` evaluated with `(now, lastActivity, pressureLevel, quiescence, ttlSetting)`.
- **Coarse repeating tick** — the parked-sessions background driver already runs one; the TTL check piggybacks on a coarse timer, not precise per-deadline timers.

## Goals / Non-Goals

**Goals:**

- The resident model has an automatic path out of RAM: memory pressure (fast path) and quiescence-keyed idle TTL (backstop).
- Eviction is *invisible-correct*: next use transparently re-loads via the existing single-flight path; lifecycle transitions `loaded → ready`, never a failure state.
- The decision logic is pure and unit-tested in Core (`swift build` / `swift test`); only the `DispatchSource` wrapper is untestable glue.
- The spec's existing "on memory pressure" promise becomes true; stale comments get corrected.

**Non-Goals:**

- No change to *session* lifecycle (parked-sessions eviction of sessions is a different axis and untouched).
- No change to fleet residency planning — the planner keeps owning multi-model admission; this change only adds new *callers* of the same `evict()`.
- No on-disk deletion; memory only.
- No eviction of the CPU ternary lane's small resident footprint (cost/benefit is upside-down: ~32× smaller weights, re-warm latency on every structured burst).
- No speculative "smart" reload (pre-warming on predicted use) — out of scope, the lazy path is the contract.

## Decisions

### D1 — A pure `EvictionPolicy`, not scattered checks

One pure function decides: given `now`, `lastAIActivity`, current `MemoryPressureLevel` (`.nominal/.warning/.critical`), a `QuiescenceSnapshot`, and the TTL setting, return `.keep` or `.evict(reason:)`. `ModelManager` executes the verdict; nothing else decides. This mirrors `ResidencyPlanner` (pure evict/admit against a budget) and keeps every rule testable without real weights or real pressure.

Policy rules (v1):

| Trigger | Condition to evict |
|---|---|
| **Critical pressure** | No turn in flight, no load in flight. (System health outranks an open chat; the next message pays a reload.) |
| **Warning pressure** | Fully quiescent (no in-flight turn, no foreground-active session, no scheduled parked work in the horizon). |
| **Idle TTL** | Fully quiescent continuously for ≥ TTL. `ttl == 0` disables this trigger only — pressure triggers stay live. |

*Alternative considered:* evict on warning unconditionally (LM Studio-style). Rejected — their reload is cheap JIT churn; ours is a multi-second 17 GB event, so warning-level eviction respects an open conversation.

### D2 — Quiescence is an injected snapshot closure, computed where the scheduler lives

`ModelManager` gains `quiescence: @MainActor () -> QuiescenceSnapshot` (injected at composition in `AppCoordinator`, like `fleetFreeBytes`). The snapshot carries: `turnInFlight`, `foregroundSessionActive`, `nextScheduledWork: Date?`. `foregroundSessionActive` means *any* live conversational surface — an open chat session **or an open voice conversation** (the voice change wires its session in through the same flag; a user mid-dialogue must never pay a TTL/warning eviction between spoken turns). The parked-sessions scheduler already knows all three; it only *exposes* them — no behavioral change to sessions. Same-actor (`@MainActor`) evaluation closes the evict-vs-just-scheduled race: a parked advance scheduled after the snapshot is read lands after the evict completes and simply triggers a lazy reload.

*Alternative considered:* `ModelManager` observing scheduler state via Combine/Observation. Rejected — a pull-based snapshot at decision time is simpler, race-free on one actor, and matches the injected-probe idiom.

### D3 — Pressure arrives through a small injected source; the `DispatchSource` lives in composition

A `MemoryPressureObserving` seam (current level + change callback) with two conformers: the real one wrapping `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])` (composition root, app target), and a settable fake for Core tests. On a pressure event the manager evaluates `EvictionPolicy` immediately; it also re-evaluates on the coarse tick (pressure can persist).

### D4 — TTL check rides a coarse tick; activity stamping is centralized

`ModelManager.runtime(requiring:)` — the single entry point every AI request already flows through — stamps `lastAIActivity` on each successful return. A coarse repeating timer (~60 s; same idiom as the parked background driver) evaluates the policy. Continuous-quiescence is derived, not accumulated: the policy asks "has anything stamped activity, and has the snapshot been quiescent, since `now - ttl`?" — restarting the app restarts the window (safe: a fresh launch has nothing resident anyway).

### D5 — Both triggers route through the existing `evict()`; guards live in the manager

No second teardown path. Guards checked at execution time (not just policy time): a load in flight (`coalescedLoad` active) or a turn in flight aborts the evict — re-evaluated on the next tick. Lifecycle transitions `loaded → ready` exactly as the manual button does today; `reconcileWithDisk` semantics are untouched.

### D6 — Settings surface: one TTL value, pressure always on

`AppSettings.aiIdleEvictMinutes` (default **60**, `0` = never — matches today's keep-forever for users who opt out). Pressure-driven eviction is not a setting: it's the spec's existing promise and only fires when quiescent (warning) or between turns (critical). The Settings/Hub model row keeps showing resident state truthfully ("Loaded" vs "Ready"), which it already renders from lifecycle state — no new UI required; the manual evict button remains.

### D7 — `maxConcurrentStreams` recompute: wire the claim narrowly

`BatchedLLMRuntime.maxConcurrentStreams` documents recomputation "when memory pressure is reported." Scope here: on a pressure event while a batched turn is in flight (evict blocked), the manager pokes the resident batched runtime to recompute its budget from a fresh free-memory probe (`ConcurrencyBudget` already takes free bytes as input). If that lands poorly in implementation, the fallback is correcting the comment — either way the claim stops being false.

## Risks / Trade-offs

- [Critical-pressure evict while a chat window is open] → next message pays a multi-second reload. Accepted: under critical pressure the alternative is macOS paging other apps to protect idle weights. The reload is the existing, observable `loading` state — no new UX.
- [Evict races a just-scheduled parked advance] → same-actor snapshot (D2) makes the ordering deterministic; worst case is a benign transparent reload, never a lost turn.
- [Pressure thrash: evict → reload on demand → pressure again] → reloads only happen on explicit demand (user turn or scheduled advance), never automatically after an evict; if the system is genuinely out of memory, the load path's existing `hardwareSupports`/budget gates still apply.
- [TTL evicts between a user's "thinking pauses" in a long-lived but idle chat] → `foregroundSessionActive` in the quiescence snapshot protects an open/active session from TTL and warning-level eviction; only critical pressure overrides.
- [Fake-pressure testability drift] → the policy is pure and the observer is a seam; the only untested code is the ~20-line `DispatchSource` wrapper in the composition root.

## Open Questions

- Default TTL: 60 min (LM Studio parity) vs something longer given reload cost — feel-tunable, ship 60 and adjust.
- Should the Hub fleet roster surface "evicted by pressure at HH:MM" as a passive note? (Pure nicety; not required for correctness.)
