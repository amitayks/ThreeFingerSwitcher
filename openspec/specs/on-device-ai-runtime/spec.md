# on-device-ai-runtime Specification

## Purpose

Define the swappable, on-device language-model runtime that backs the AI command feature: a single `LLMRuntime` abstraction over a v1 Gemma 4 (MLX-Swift) conformer, streaming and schema-validated structured output with repair/retry, vision input, model lifecycle (opt-in download, integrity-verified, lazy-loaded, resident, evictable), a capability-based model registry, cancellable generation, and a capable-hardware-only target.
## Requirements
### Requirement: Swappable model runtime abstraction
The system SHALL access all language-model functionality through a single `LLMRuntime` abstraction that exposes the runtime's capabilities (at least `text`, `vision`; later `audio`), a streaming text-generation call, and a structured-output call that returns a typed, schema-validated value. Feature code (the band, the executor, the tasks) SHALL depend only on this abstraction and SHALL NOT reference any concrete model or framework directly, so that an additional model (another Gemma 4 size, a future Gemma, Apple Foundation Models, or a cloud model) can be added later as one new conformer without changing feature code.

#### Scenario: Feature code is model-agnostic
- **WHEN** the band executor needs a result
- **THEN** it calls the `LLMRuntime` abstraction and never a concrete model type

#### Scenario: Adding a model is additive
- **WHEN** a new model conformer is introduced
- **THEN** it can be selected without modifying the band, executor, or task code

### Requirement: On-device Gemma 4 via MLX-Swift
The system SHALL provide a v1 runtime conformer that runs **Gemma 4 in-process on Apple Silicon via MLX-Swift**, defaulting to the largest text+vision model the runtime is configured for (Gemma 4 31B). Generation SHALL run fully on-device (no network at inference time) and SHALL stream output tokens incrementally.

#### Scenario: Inference is local and offline
- **WHEN** a command runs with the on-device runtime and the network is unavailable
- **THEN** generation still completes using the local model

#### Scenario: Output streams incrementally
- **WHEN** a command is generating
- **THEN** partial tokens are delivered as they are produced, not only at completion

### Requirement: Schema-targeted structured output with validation and repair
For structured-output calls, the runtime SHALL accept a JSON Schema, request output matching it, and **validate** the result against the schema, **repairing or retrying** within a bounded loop when the result does not conform. The runtime MAY use grammar-guided/constrained decoding as one technique but SHALL NOT depend on hard token-level caging as the sole guarantee, and SHALL preserve the model's ability to reason freely and to return a **declined / "not applicable"** result rather than being forced to emit a well-formed-but-fabricated value. The runtime SHALL NOT rely on brittle regex-only parsing of free-form text as the means of obtaining structure.

#### Scenario: Structured result conforms to schema
- **WHEN** a structured-output call is made with a JSON Schema for a task
- **THEN** the returned value parses and validates against that schema

#### Scenario: Non-conforming output is repaired or retried
- **WHEN** the model's first attempt does not satisfy the schema
- **THEN** the runtime repairs or retries within a bounded loop and returns a conforming value, or reports that it could not produce one

#### Scenario: The model may decline rather than fabricate
- **WHEN** the input does not fit the requested structure (for example, it is not a meeting)
- **THEN** the runtime can return a "not applicable" / declined result instead of inventing values to satisfy the schema

### Requirement: Vision input
The runtime conformer SHALL accept an image input (e.g. a captured screen region) alongside the text prompt for vision-capable commands, and SHALL produce a text or structured result describing/acting on that image. In v1 the **Gemma 4 (MLX-Swift) conformer SHALL actually process image input** rather than refusing it: when the selected model advertises the `vision` capability and a request carries an image, the conformer SHALL drive an image-aware generation path (consuming the captured PNG bytes) and generate a grounded result. The conformer SHALL NOT reject a vision request from a vision-capable model with `unsupportedModality(.vision)`. A text-only fast path SHALL be preserved for non-image requests so text commands do not pay the multimodal load/memory cost.

#### Scenario: Screen region is interpreted
- **WHEN** a vision command supplies a captured screen region and a prompt such as "what is this?"
- **THEN** the runtime returns a text answer grounded in the image

#### Scenario: The v1 Gemma conformer serves a vision request
- **WHEN** a vision-capable Gemma 4 model receives a request carrying an image
- **THEN** the conformer processes the image through its image-aware pipeline and streams a grounded result, rather than throwing `unsupportedModality(.vision)`

#### Scenario: Text commands keep the text-only fast path
- **WHEN** a request carries no image
- **THEN** the conformer serves it on the text-only path without loading the multimodal graph

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

### Requirement: Model registry and capability-based selection
The system SHALL maintain a registry describing each known model (identifier, size, integrity hash, download source, and capability set), and SHALL select the model for a given command by its required capabilities — e.g. a vision command requires a vision-capable model. The registry SHALL make it possible to route a future audio command to an audio-capable Gemma 4 model without changing feature code.

#### Scenario: Vision command selects a vision-capable model
- **WHEN** a command requires vision and the default model is vision-capable
- **THEN** that model is selected to serve it

#### Scenario: Registry drives upgrades
- **WHEN** a newer model entry is added to the registry
- **THEN** it can become the selected model via configuration, without code changes in the feature

### Requirement: Cancellable generation
Generation (both streaming and structured) SHALL be cancellable mid-flight so that discarding a result (a horizontal discard swipe in the preview) stops the model work promptly and frees its resources.

#### Scenario: Discard cancels generation
- **WHEN** the user discards a streaming result before it completes
- **THEN** the underlying generation is cancelled and stops producing tokens

### Requirement: Targets capable hardware only
The runtime SHALL target current, high-end Apple Silicon and use the best model the configuration specifies; it SHALL NOT provide a degraded small-model path for low-end hardware in this version. If the hardware or model cannot satisfy the feature, the system SHALL report the feature as unavailable rather than silently running a worse experience. The runtime SHALL NOT assume a **single GPU compute lane**: it MAY additionally use a **CPU compute lane** running a small ternary model **concurrently** with the GPU lane to serve short, frequent, structured work — and this CPU lane SHALL exist as a **bandwidth optimization for capable hardware, NOT as a degraded fallback for weak hardware**. The small ternary model on the CPU lane SHALL NOT be construed as the "degraded small-model path" this requirement forbids; it is an additional concurrent lane for light work on capable hardware, never a substitute for the GPU model on incapable hardware.

#### Scenario: Unsupported configuration reports unavailable
- **WHEN** the required model cannot be run on the current machine
- **THEN** the feature reports itself unavailable instead of degrading silently

#### Scenario: The CPU ternary lane is an optimization, not a low-end fallback
- **WHEN** the CPU compute lane is in use on capable hardware
- **THEN** it runs a small ternary model for short structured work **alongside** the GPU model, and it is never offered as a substitute for the GPU model on weak hardware

### Requirement: Two compute lanes with a pure role-to-lane policy
The system SHALL model compute as **two physical lanes** — a **GPU lane** and a **CPU ternary lane** — and SHALL assign each unit of agent work to a lane via a **pure, total role-to-lane policy**. Heavy work SHALL route to the GPU lane: the **foreground generation** (the visible reply) and **media diffusion**. Short, frequent, structured work SHALL route to the CPU ternary lane: the **router structured turn**, **classification** decisions (such as should-park / needs-you / which-skill), **memory retrieval/index** work, and **parked-subagent** background advances. The policy SHALL be a deterministic function of the work role alone (the same role always maps to the same lane), so lane assignment is reproducible and cannot drift between call sites. The GPU lane SHALL remain the existing batched/continuous-batching runtime; this requirement adds the CPU lane beside it and does not change the GPU lane's batching behavior.

#### Scenario: Heavy work routes to the GPU lane
- **WHEN** the work is the foreground reply or a media diffusion job
- **THEN** the role-to-lane policy assigns it to the GPU lane

#### Scenario: Short structured work routes to the CPU ternary lane
- **WHEN** the work is a router structured turn, a classification, a memory retrieval, or a parked-subagent advance
- **THEN** the role-to-lane policy assigns it to the CPU ternary lane

#### Scenario: The policy is deterministic and total
- **WHEN** the same work role is presented to the policy more than once
- **THEN** it always maps to the same lane, and every defined role has a lane

### Requirement: The CPU ternary lane is a second runtime conformer, not a new protocol
The CPU ternary lane SHALL be served by **another conformer of the existing language-model runtime abstraction**, carrying a small ternary/BitNet-class model — NOT a new, separate runtime protocol. Feature code (the band, the executor, the router, the tasks) SHALL continue to depend only on the single runtime abstraction and SHALL select the CPU-lane runtime **by lane** (via the model registry's lane-tagged descriptor), never by referencing a concrete CPU runtime type. Adding the CPU lane SHALL therefore require no change to feature code beyond lane-aware selection.

#### Scenario: The CPU lane is selected by lane, not by concrete type
- **WHEN** work is routed to the CPU ternary lane
- **THEN** the system resolves the lane's runtime through the single runtime abstraction tagged with that lane, and feature code never references a concrete CPU runtime type

#### Scenario: Adding the CPU lane is additive to feature code
- **WHEN** the CPU ternary conformer is introduced
- **THEN** the band, executor, router, and tasks compile and run unchanged, depending only on the shared runtime abstraction

### Requirement: The CPU ternary lane serves short bursts only, never the long reply
The CPU ternary lane SHALL serve only **short, frequent, structured** work. Because a CPU ternary decode is **slower per token** than a GPU batched decode, the **long foreground reply SHALL NEVER be routed to the CPU lane**; it SHALL always run on the GPU lane. The CPU lane's value SHALL come from running its short bursts **concurrently** with the GPU reply (not from being faster per token), justified by the measured hardware facts: GPU prefill is up to ~4× faster on the neural accelerators (heavy generation belongs on the GPU); token generation is bandwidth-bound on the ~153 GB/s unified-memory bus; and the ternary model's weights are roughly 32× smaller, so reading them per token consumes only a small fraction of that bandwidth — letting the CPU lane run without meaningfully contending with the GPU reply for the shared bus.

#### Scenario: The long reply stays on the GPU lane
- **WHEN** the foreground reply is generated
- **THEN** it runs on the GPU lane and is never dispatched to the CPU ternary lane, even when the GPU lane is busy

#### Scenario: Short structured bursts run concurrently on the CPU lane
- **WHEN** a router turn or a classification runs while a foreground reply streams on the GPU
- **THEN** the structured burst runs on the CPU ternary lane at the same time, rather than queuing behind the GPU decode loop

### Requirement: Cross-lane concurrency with a residency budget that never starves the GPU reply
The system SHALL run the GPU lane and the CPU ternary lane **concurrently** under a **pure residency budget**. The budget SHALL account for the resident GPU chat weights (read once), the GPU key/value caches per stream, and the **small** ternary residency footprint (the ~32×-smaller ternary weights), and SHALL admit the ternary model to **co-reside** with the current GPU batch and key/value caches under the unified-memory budget. The arbiter SHALL bound CPU-lane concurrency on its **own** small cap and SHALL NOT borrow GPU batch slots. Two invariants SHALL hold: (1) a heavy GPU generation SHALL NEVER be made to wait on CPU-lane work; (2) CPU-lane bursts SHALL NEVER preempt or starve the foreground GPU reply. A CPU-lane unit that cannot be admitted under its own cap or the residency budget in a given step SHALL **wait** (remain runnable) rather than be treated as a failure. The residency budget and the arbiter SHALL be **pure** (free memory and time are inputs), so their decisions are deterministically testable without real GPU work.

#### Scenario: The ternary model co-resides cheaply with the GPU batch
- **WHEN** the residency budget is computed with the GPU chat weights and key/value caches resident
- **THEN** the small ternary model is admitted to co-reside, fitting where a second full chat model would not

#### Scenario: A heavy GPU generation is never blocked by CPU work
- **WHEN** CPU-lane bursts are active and a foreground GPU generation needs to advance
- **THEN** the GPU generation advances without waiting on the CPU-lane work

#### Scenario: CPU bursts never starve the foreground reply
- **WHEN** many CPU-lane bursts are queued while the foreground GPU reply is streaming
- **THEN** the foreground reply continues unimpeded and the CPU bursts are bounded by their own cap

#### Scenario: An unadmittable CPU burst waits, not fails
- **WHEN** a CPU-lane burst cannot be admitted under the CPU cap or residency budget in the current step
- **THEN** it waits for a later step and is not reported as a failure

#### Scenario: The budget and arbiter are deterministic
- **WHEN** the residency budget and arbiter are evaluated with a given free-memory figure and timestamp
- **THEN** their decisions depend only on those inputs and the lane state, so they are reproducible in tests

### Requirement: An additive lane-affinity hint dispatches a parked subagent to the CPU lane concurrently with a foreground GPU generation
The system SHALL carry a **lane-affinity hint** — the compute lane a runnable session prefers, derived from its work role via the role-to-lane policy — and SHALL consume it **additively**, without changing the pinned shapes of the parked-session scheduler's runnable-set request or the batched runtime's batch-step entry point. The dispatcher SHALL read each runnable session's lane affinity and route a **CPU-ternary-affined** session (such as a parked subagent) to the **CPU ternary lane** while the GPU batched runtime keeps serving the foreground and GPU-affined sessions. The net effect SHALL be that a **parked subagent advances on the CPU lane at the same time** as a foreground GPU generation, rather than waiting for a GPU batch slot. This hint SHALL be additive on the existing scheduler and batched-runtime seams; it SHALL NOT require those seams' methods to change signature.

#### Scenario: A parked subagent runs on CPU while the foreground generates on GPU
- **WHEN** a parked subagent session is runnable and a foreground GPU generation is in flight
- **THEN** the subagent is dispatched to the CPU ternary lane and advances concurrently with the foreground GPU generation

#### Scenario: The lane-affinity hint is additive to the existing seams
- **WHEN** the lane-affinity hint is introduced
- **THEN** the parked scheduler's runnable-set request and the batched runtime's batch-step entry point keep their existing shapes, and the hint is read alongside them rather than by changing their signatures

#### Scenario: Affinity follows the work role
- **WHEN** a session's lane affinity is derived
- **THEN** it equals the lane the role-to-lane policy assigns to that session's work role (a parked-subagent advance maps to the CPU lane; a foreground generation maps to the GPU lane)

### Requirement: The CPU lane is gated by the master toggle and off means one-lane behavior
The CPU ternary lane SHALL be gated by a sub-capability flag under the master full-potential toggle. When the flag is **off**, the system SHALL NOT install the CPU ternary runtime and SHALL route **all** work to the GPU lane, behaving exactly as a single-lane build — a one-lane (fleet-of-one) configuration SHALL remain valid. When the flag is on, the role-to-lane policy SHALL take effect. The cost of enabling the CPU lane — a small additional resident model and CPU heat under sustained structured bursts — SHALL be disclosed where the toggle is offered.

#### Scenario: Off routes everything to the GPU lane
- **WHEN** the CPU-lane flag is off
- **THEN** no CPU ternary runtime is installed and every work role routes to the GPU lane, exactly as a single-lane build

#### Scenario: On enables the two-lane policy
- **WHEN** the CPU-lane flag is on
- **THEN** the role-to-lane policy takes effect and short structured work routes to the CPU ternary lane

#### Scenario: The CPU lane's cost is disclosed
- **WHEN** the CPU-lane toggle is offered to the user
- **THEN** its RAM and heat cost is stated alongside the capability, not hidden

### Requirement: Reasoning (thinking) is toggle-gated and streamed as a separate channel
The runtime SHALL support an optional **reasoning** mode carried on the request, in which the model thinks before answering. When reasoning is enabled, the runtime SHALL make the model reason (for Gemma 4, via the `enable_thinking` chat-template flag — the model does NOT think by default) and SHALL stream output as **two distinct channels**, tagging each emitted token as **thinking** or **response**. Only the **response** channel SHALL be returned for in-place commit and for structured/task output; the **thinking** channel SHALL NEVER be committed to the front app nor parsed as a task action. When reasoning is **disabled** (the per-request default), the model SHALL produce response-only output and incur no thinking latency.

#### Scenario: Reasoning streams thinking and response as separate channels
- **WHEN** a request with reasoning enabled is generated
- **THEN** the runtime streams thinking-channel and response-channel tokens distinctly, tagging each, and only the response is returned for commit

#### Scenario: Thinking never reaches the document or a task
- **WHEN** reasoning is enabled and the result is committed in place or parsed as a task action
- **THEN** only the response text is written/parsed; the thinking is never inserted into the front app nor used as the task action

#### Scenario: Reasoning off has no thinking latency
- **WHEN** a request has reasoning disabled
- **THEN** the model produces response-only output and does not generate a thinking block

#### Scenario: A per-command override beats the global default
- **WHEN** a command carries an explicit reasoning override (on or off) that differs from the global default
- **THEN** the request's reasoning follows the command's override (and a command with no override follows the global default), for in-place and task commands alike

### Requirement: Audio input is carried on the request seam and honestly refused until served
`LLMRequest` and `LLMChatRequest` SHALL carry an `audio` input (encoded audio byte payloads, defaulting to empty) alongside `images`, with a `requiresAudio` derivation, and capability selection SHALL treat a non-empty `audio` as requiring the `.audio` modality through the SAME `selectModel(requiring:)` path as vision. Until a conformer actually serves audio, every runtime — including the stub — SHALL REJECT a non-empty `audio` request with `unsupportedModality(.audio)`: the seam is statically typed and carried end-to-end, and its unimplemented half is an explicit, tested refusal, never a silently-ignored field. (This is the v4+ foundation for direct audio-in Gemma via the vendored audio tower; wiring the tower is a separate change.)

#### Scenario: Audio requests select for the audio capability
- **WHEN** a request carries non-empty audio and model selection runs
- **THEN** only descriptors advertising `.audio` satisfy it, and `RuntimeError.unavailable` is reported when none does

#### Scenario: A non-audio runtime refuses rather than ignores
- **WHEN** a request with non-empty audio reaches a runtime that does not serve audio (including the test stub)
- **THEN** it fails with `unsupportedModality(.audio)` — the audio bytes are never silently dropped

#### Scenario: Empty audio changes nothing
- **WHEN** requests carry the default empty audio
- **THEN** behavior is byte-for-byte identical to before the field existed (text and vision paths unaffected)

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

