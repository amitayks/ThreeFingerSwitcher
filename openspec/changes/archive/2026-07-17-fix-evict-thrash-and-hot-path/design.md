# Design: fix-evict-thrash-and-hot-path

## Context

Root cause analysis of the reported "late swipes + laggy Mac": a 17 GB resident model keeps macOS at
chronic `.warning` memory pressure; the warning trigger fired whenever the *notch* was quiet — but the
user was chatting through the *canvas*, which the snapshot never saw. Evict → reload (multi-second,
bus-saturating) → pressure spike → evict again: a reload storm, the exact swap-storm class the
single-flight coalescing change was built to prevent. Secondary: `touchEngine.onFrame` is the
latency-critical gesture path; the abort hook added settings reads + lazy `@MainActor` instantiation
per contact frame.

## Goals / Non-Goals

**Goals:** kill the thrash loop deterministically; make the quiescence snapshot complete; make the
per-frame cost of the abort hook one stored-Bool read; keep all spec-level behavior honest.

**Non-Goals:** no change to critical-pressure semantics, TTL semantics, or any voice/computer-use
behavior; no revert of automatic eviction (the feature stays — its trigger conditions get correct).

## Decisions

- **D1 — Idle floor over debounce/cooldown.** A cooldown-after-evict still allows a first wrong evict
  mid-conversation; an idle floor (`now - lastActivity ≥ 300s` for `.warning`) prevents the wrong
  evict entirely and needs no new state — `lastActivity` already exists and reloads re-stamp it, so
  every reload buys an automatic grace window. Critical stays immediate: with the system genuinely
  out of memory, a reload-on-next-use is the correct price.
- **D2 — Snapshot completeness at the composition root.** The coordinator (the only place that sees
  every surface) ORs canvas + executor + notch + voice into the snapshot. `AICommandExecutor` exposes
  `isTurnInFlight` (`.loadingModel`/`.streaming`) mirroring the engine's flag; `.reviewingAction`
  counts as foreground-active (a user mid-review is mid-conversation), not turn-in-flight.
- **D3 — Armed-flag hot path.** Two plain stored Bools on the coordinator (`agentActingNow`,
  `voicePhaseLive`), updated by `$isActing`/`$phase` sinks installed INSIDE the respective lazy
  initializers — so a touch frame can never instantiate the agent/voice stack, and the per-frame
  check is `fingerCount > 0 && (agentActingNow || voicePhaseLive)` over stored Bools. Sinks fire on
  state changes only (rare), never per frame.

## Risks / Trade-offs

- [A genuinely idle machine under chronic warning keeps the model 5 min longer than before] →
  intended: the floor is the difference between reclaim and thrash.
- [Executor states beyond streaming (e.g. long `reviewingAction`) block TTL] → correct: the user is
  mid-conversation; TTL measures quiescence, not wall time.
