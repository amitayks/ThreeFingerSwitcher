# Delta: on-device-ai-runtime — model-idle-ttl-and-memory-pressure

## MODIFIED Requirements

### Requirement: Model lifecycle management
The system SHALL manage model weights via a lifecycle: weights are downloaded only after the user opts in (a multi-gigabyte, quantized QAT download), the download SHALL be resumable and **integrity-verified** before use, the model SHALL be **lazy-loaded** on first use, **kept resident** between calls to avoid repeated cold loads, **evicted** (from memory) on memory pressure or when the opt-in is turned off, and **deletable** (from disk) per model. Deleting a model SHALL remove its weights from the exact on-disk location the runtime loads from, so the model reads as not-downloaded afterwards and is not re-discovered as downloaded; a delete SHALL also evict the model if it is the one resident. The **displayed** lifecycle status SHALL reflect the **currently selected** model (each model's own on-disk/resident status), not a single global status carried over from a previously active model. While a model is loading, the system SHALL expose a loading state to the UI rather than blocking silently.

**Loading SHALL be single-flight:** at most ONE heavy load runs at any moment. Concurrent requests for the model while a load is in flight SHALL **join** that load and receive its one result (the load cost — and its memory footprint — is paid exactly once; two full weight sets are NEVER resident from racing requests); a load failure SHALL propagate to every joined requester and clear the in-flight state so a later retry starts fresh. A request for a **different** model while a load is in flight SHALL wait for the in-flight load to settle before proceeding (never two concurrent heavy loads).

**The runtime's GPU buffer cache SHALL be bounded:** the MLX-backed runtime SHALL set an explicit buffer-cache limit at composition so freed generation buffers return to the OS — the resident footprint tracks the model's size instead of growing without bound across turns.

**Eviction SHALL be automatic, not only manual.** Memory-pressure eviction SHALL be genuinely wired (a real OS pressure observer, not an aspiration): on **critical** pressure the resident runtime SHALL be evicted whenever no generation turn and no load is in flight; on **warning** pressure it SHALL be evicted only when the AI system is **fully quiescent** (no turn in flight, no foreground-active session — an open chat *or voice* conversation — no parked work scheduled within the horizon). Additionally, an **idle-TTL backstop** SHALL evict the resident runtime after the AI system has been continuously quiescent for a user-configurable window (default generous; `0` SHALL disable the TTL trigger only — pressure triggers remain live). The CPU ternary lane's small resident footprint SHALL be exempt from both triggers.

**The eviction decision SHALL be a pure policy** — evaluated with time, last-activity, pressure level, and a quiescence snapshot as explicit inputs — so every rule is deterministically testable without real weights or real OS pressure. All automatic triggers SHALL route through the same single eviction path as the manual control, and an eviction SHALL transition the lifecycle `loaded → ready` (weights remain on disk).

**Eviction SHALL be invisible-correct:** the next request after an automatic eviction SHALL transparently lazy-load again through the single-flight load path — identical to first use after relaunch — surfacing the existing observable loading state and never a failure state, a lost turn, or a stranded scheduled advance.

#### Scenario: No download until opt-in
- **WHEN** the AI commands opt-in is off
- **THEN** no model weights are downloaded

#### Scenario: Deleting a model frees its weights and does not re-discover
- **WHEN** a downloaded model is deleted (per-model, or via the danger-zone clear)
- **THEN** its weights are removed from the directory the runtime loads from
- **AND** re-opening the AI surface or re-enabling the opt-in shows it as not-downloaded rather than "downloaded"

#### Scenario: Status follows the selected model
- **WHEN** the user switches the selected model in the picker
- **THEN** the displayed status reflects that model's own on-disk/resident state, not the previously selected model's

#### Scenario: Corrupt download is rejected
- **WHEN** a downloaded model fails its integrity check
- **THEN** it is not loaded and the user is told the download must be retried

#### Scenario: Model stays resident between calls
- **WHEN** two commands are run in succession with the model already loaded
- **THEN** the second run does not pay a full cold-load cost

#### Scenario: Concurrent requests share one load
- **WHEN** two AI requests race while the model is not yet resident (e.g. a background advance and a user turn during the multi-second load window)
- **THEN** the heavy load runs exactly once, both requests receive the same loaded runtime, and two full weight sets are never resident simultaneously

#### Scenario: A failed shared load fails every joiner and permits retry
- **WHEN** the in-flight load fails while other requests have joined it
- **THEN** every joined request observes the failure (never a hang or a silent stub), and a subsequent request starts a fresh load

#### Scenario: Loading state is observable
- **WHEN** the model is loading on first use
- **THEN** the preview surface shows a loading state

#### Scenario: The GPU buffer cache does not grow without bound
- **WHEN** many generation turns run on the loaded model
- **THEN** the runtime's buffer cache stays within its configured limit and the app's resident footprint tracks the model size rather than creeping upward with use

#### Scenario: Idle TTL evicts a quiescent system
- **WHEN** no turn is in flight, no session is foreground-active, no parked work is scheduled, and the state has held continuously for the configured TTL
- **THEN** the resident runtime is evicted via the single eviction path and the lifecycle reads `ready` (weights still on disk)

#### Scenario: TTL of zero restores keep-forever
- **WHEN** the TTL setting is `0` and the system stays quiescent indefinitely
- **THEN** the TTL trigger never fires, while memory-pressure eviction remains armed

#### Scenario: Warning pressure respects an open conversation
- **WHEN** warning-level memory pressure is reported while a session is foreground-active (but no turn is in flight)
- **THEN** the resident runtime is NOT evicted

#### Scenario: Critical pressure evicts between turns
- **WHEN** critical memory pressure is reported with no turn and no load in flight (even if a session is foreground-active)
- **THEN** the resident runtime is evicted, and the session's next message transparently triggers a fresh single-flight load with the observable loading state

#### Scenario: Never evict mid-turn or mid-load
- **WHEN** any automatic trigger fires while a generation turn or a load is in flight
- **THEN** the eviction is not executed, and the policy is re-evaluated on the next tick

#### Scenario: Eviction never strands scheduled work
- **WHEN** a parked advance is scheduled within the quiescence horizon
- **THEN** the TTL and warning-pressure triggers treat the system as not quiescent, and an advance that lands after an eviction lazy-loads transparently rather than failing

#### Scenario: The pure policy is testable without real pressure
- **WHEN** the eviction policy is evaluated in tests with faked time, activity, pressure level, and quiescence inputs
- **THEN** it returns deterministic keep/evict verdicts for every rule above, with no OS observer or resident model involved
