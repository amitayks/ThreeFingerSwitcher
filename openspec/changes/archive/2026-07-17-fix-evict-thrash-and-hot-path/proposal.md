# Proposal: fix-evict-thrash-and-hot-path

## Why

`model-idle-ttl-and-memory-pressure` shipped a regression: with a ~17 GB model resident, macOS sits at **chronic** warning-level memory pressure on most machines — the app's *normal* state, not an emergency. The warning trigger treated it as exceptional, and the quiescence snapshot was **blind to the launcher canvas and the executor's in-flight turns** (it only saw notch sessions). Net effect: the 60 s tick evicts between canvas turns → the next command pays a full 17 GB reload → the reload saturates the memory bus and re-spikes pressure → repeat. A reload storm reads exactly as the user reported: swipe triggers respond late and the whole Mac gets laggy. Secondarily, the touch hot path (`touchEngine.onFrame`, the latency-critical gesture pipeline) gained per-frame reads of settings and lazy `@MainActor` objects.

## What Changes

- **Warning-pressure eviction gains an idle floor**: `.warning` evicts only when the system is fully quiescent AND nothing has stamped AI activity for ≥ 5 minutes (`EvictionPolicy.warningIdleFloor`). Chronic warning pressure between active turns no longer thrashes; a genuinely idle app under pressure still frees RAM. `.critical` stays immediate (turn/load-guarded) — real emergencies outrank comfort.
- **The quiescence snapshot sees every conversational surface**: the coordinator ORs in the AI canvas (`launcherOverlay.canvasActive` → `foregroundSessionActive`) and the executor's `.loadingModel`/`.streaming` states (→ `turnInFlight`), alongside the notch sessions and voice.
- **The touch hot path is one stored-Bool read**: the per-frame abort hook arms via cached flags (`agentActingNow`, `voicePhaseLive`) maintained by Combine sinks installed inside the lazy initializers — the arbiter/voice stack is never instantiated by a touch frame, and settings are never read per frame.
- **Eviction tick tolerance**: the 60 s timer gets 10 % tolerance (fewer exact-fire wakeups).

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `on-device-ai-runtime`: the automatic-eviction requirement is corrected — warning-level pressure requires sustained idleness (chronic pressure with a resident large model is normal operation and must not thrash), and the quiescence inputs are defined to cover ALL conversational surfaces (canvas + executor + notch + voice).

## Impact

- **Code**: `EvictionPolicy.swift` (idle floor), `AppCoordinator.swift` (snapshot closure + hot-path flags), `AICommandExecutor.swift` (an `isTurnInFlight` read), `ModelManager.swift` (timer tolerance). Tests updated for the floor.
- **Risk**: none new — strictly narrows when eviction fires and removes ambient work.
