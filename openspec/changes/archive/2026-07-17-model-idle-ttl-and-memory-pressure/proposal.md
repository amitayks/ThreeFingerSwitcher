# Proposal: model-idle-ttl-and-memory-pressure

## Why

Once loaded, the ~17 GB resident model has **no automatic path back out of RAM**: `evict()` fires only when the opt-in is turned off, when a fleet residency plan names it a victim, or when the user presses the manual "Evict from memory" button. The `on-device-ai-runtime` spec already promises eviction "on memory pressure" — and code comments (`ModelManager.swift:667/674`, `LLMRuntime.swift:355`) cite memory pressure as a trigger — but **no memory-pressure observer is wired anywhere**; the promise is aspirational text. A user who ran one AI command at breakfast carries a 17 GB resident footprint all day, and under system memory pressure macOS pages *other* apps out to protect weights nobody is using.

## What Changes

- **Wire a real memory-pressure observer** (`DispatchSource.makeMemoryPressureSource`) as the *fast* evict path: on warning/critical pressure, evict the resident runtime — but only when the AI system is quiescent (never mid-turn).
- **Add an idle-TTL backstop keyed to AI-system quiescence, not wall-clock alone**: when there is no in-flight turn, no scheduled parked work, and every session has been idle for the TTL window, evict the resident runtime. Reload is a slow multi-second event here (unlike LM Studio's cheap JIT churn), so the TTL is generous by default and configurable; `0` = never (today's behavior).
- **Eviction is invisible-correct**: the next request after an eviction transparently lazy-loads again through the existing single-flight `coalescedLoad` path — same behavior as first use after relaunch. No user-visible failure mode is introduced; lifecycle state transitions `loaded → ready` (weights on disk, not resident).
- **Guards**: never evict while a turn is in flight, while parked work is scheduled within the TTL horizon, or while a load is in progress; the CPU ternary lane's small resident footprint is exempt (evicting it buys almost nothing and costs re-warm latency).
- **Honest comments**: the existing "on memory pressure" doc comments become true, or are corrected where the behavior is deliberately narrower (e.g. `BatchedLLMRuntime.maxConcurrentStreams` recompute — wire the pressure signal it claims to react to, or fix the claim).

## Capabilities

### New Capabilities

_None — this lands inside the existing runtime-lifecycle capability._

### Modified Capabilities

- `on-device-ai-runtime`: the "Model lifecycle management" requirement gains real, testable eviction behavior — memory-pressure-driven eviction (currently promised but unwired) and a quiescence-keyed idle TTL, both with never-mid-turn / never-strand-scheduled-work guards, plus the transparent re-load-on-next-use contract.

## Impact

- **Code**: `Sources/ThreeFingerSwitcher/AI/ModelManager.swift` (evict triggers, quiescence input, TTL timer), a new small pressure-observer seam (injected `DispatchSource` wrapper so Core tests can fake pressure), `Sources/ThreeFingerSwitcher/AI/Parked/` scheduler (expose a quiescence signal — no behavior change to sessions themselves), `AppSettings` (TTL setting, default generous, `0` = never), Hub/Settings model row (optional: show "resident/idle" status honestly).
- **Specs**: delta to `openspec/specs/on-device-ai-runtime/spec.md` (lifecycle requirement).
- **Non-goals**: no change to *session* lifecycle (`ai-parked-sessions` eviction of sessions is untouched); no change to fleet residency planning (the planner keeps owning multi-model admission — TTL/pressure eviction routes through the same `evict()` it already uses); no on-disk deletion (memory only).
- **Risk**: an eviction racing a just-scheduled parked advance — mitigated by the quiescence check running on the same actor as the scheduler signal, and by the worst case being a benign transparent reload.
