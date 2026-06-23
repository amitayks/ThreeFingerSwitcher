## MODIFIED Requirements

### Requirement: Targets capable hardware only
The runtime SHALL target current, high-end Apple Silicon and use the best model the configuration specifies; it SHALL NOT provide a degraded small-model path for low-end hardware in this version. If the hardware or model cannot satisfy the feature, the system SHALL report the feature as unavailable rather than silently running a worse experience. The runtime SHALL NOT assume a **single GPU compute lane**: it MAY additionally use a **CPU compute lane** running a small ternary model **concurrently** with the GPU lane to serve short, frequent, structured work — and this CPU lane SHALL exist as a **bandwidth optimization for capable hardware, NOT as a degraded fallback for weak hardware**. The small ternary model on the CPU lane SHALL NOT be construed as the "degraded small-model path" this requirement forbids; it is an additional concurrent lane for light work on capable hardware, never a substitute for the GPU model on incapable hardware.

#### Scenario: Unsupported configuration reports unavailable
- **WHEN** the required model cannot be run on the current machine
- **THEN** the feature reports itself unavailable instead of degrading silently

#### Scenario: The CPU ternary lane is an optimization, not a low-end fallback
- **WHEN** the CPU compute lane is in use on capable hardware
- **THEN** it runs a small ternary model for short structured work **alongside** the GPU model, and it is never offered as a substitute for the GPU model on weak hardware

## ADDED Requirements

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
