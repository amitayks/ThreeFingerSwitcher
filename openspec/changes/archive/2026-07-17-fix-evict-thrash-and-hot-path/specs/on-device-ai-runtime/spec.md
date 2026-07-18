# Delta: on-device-ai-runtime — fix-evict-thrash-and-hot-path

## ADDED Requirements

### Requirement: Automatic eviction never thrashes under chronic pressure
Warning-level eviction SHALL additionally require sustained idleness — no AI activity stamp for at
least the warning idle floor (5 minutes) — because a resident large model keeps the system at
sustained warning-level memory pressure as its NORMAL operating state. Critical-level eviction SHALL remain
immediate (guarded only by in-flight turn/load). The quiescence snapshot SHALL cover EVERY
conversational surface — the launcher canvas and the executor's in-flight/reviewing states, the notch
sessions, and a live voice conversation — so no surface's activity is invisible to the eviction
policy. A reload after eviction SHALL re-stamp activity, giving every reload an automatic grace
window. The net invariant: automatic eviction SHALL NOT produce an evict→reload cycle during an
active conversation on ANY surface.

#### Scenario: Chronic warning pressure between canvas turns does not evict
- **WHEN** warning pressure is sustained, a canvas conversation is in use, and less than the idle
  floor has passed since the last AI activity
- **THEN** the resident model is NOT evicted between turns

#### Scenario: Warning pressure with genuine idleness still reclaims
- **WHEN** warning pressure is reported and no AI activity has been stamped for at least the idle
  floor with every surface quiescent
- **THEN** the resident model is evicted

#### Scenario: An executor turn is a turn in flight
- **WHEN** the launcher-canvas executor is loading or streaming a turn
- **THEN** the quiescence snapshot reports a turn in flight and no automatic trigger evicts

#### Scenario: The gesture hot path pays one flag read
- **WHEN** touch frames stream during ordinary gestures with no agent act and no live voice phase
- **THEN** the agent-abort hook's per-frame cost is a stored-flag check — it never instantiates the
  agent/voice stack and never reads settings per frame
