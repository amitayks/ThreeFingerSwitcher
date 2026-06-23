## ADDED Requirements

### Requirement: Batched, continuous-batching concurrency over one weight read
The runtime SHALL provide a **batched** entry point that advances multiple conversation sessions concurrently by folding their queued streams into a **single forward pass per decode step**, so the model weights are read **once** per step and one token is produced for **each** active stream — rather than spawning independent single-session generations that would each re-read the weights. The batched entry point SHALL accept a set of per-session requests keyed by session identity and SHALL emit produced tokens **tagged with the session identity they belong to**, so a consumer can de-multiplex per-stream output. The **foreground active session SHALL always be granted a slot**; remaining slots SHALL be filled from the parked-session scheduler's runnable set. A stream that finishes SHALL free its slot for the next runnable session on the following step **without reloading the weights** (continuous, not static, batching). This batched runtime SHALL be the v2 concurrency mechanism; the system SHALL NOT achieve concurrency by running independent single-session generation calls in parallel.

#### Scenario: K streams advance over a single weight read
- **WHEN** several sessions are runnable and the runtime advances a decode step
- **THEN** the weights are read once and one token is produced for each active stream in that single step, rather than once per stream

#### Scenario: Per-stream tokens are de-multiplexed by session identity
- **WHEN** the batched entry point emits a token
- **THEN** the token carries the session identity it belongs to so the consumer routes it to the correct conversation

#### Scenario: The foreground session always gets a slot
- **WHEN** the batch is full and the foreground session needs to advance
- **THEN** the foreground session is granted a slot and a background session yields, rather than the foreground waiting behind background work

#### Scenario: A finished stream frees its slot without reloading weights
- **WHEN** one batched stream completes
- **THEN** its slot is filled by the next runnable session on the next step while the weights remain resident

#### Scenario: A single stream's failure does not abort the batch
- **WHEN** one batched stream errors mid-flight
- **THEN** that stream's turn becomes an observable failed state with a clean headline while the other batched streams keep producing tokens, and no stream is reported as a false success

### Requirement: Concurrency ceiling derived from unified memory
The number of concurrent streams the runtime serves SHALL be **derived from available unified memory**, not a fixed constant: the budget SHALL account for the resident weights (read once) plus one key/value cache **per concurrent stream**, where the per-stream cache size is a function of the context length and the key/value quantization. As the chosen context length grows, the affordable number of concurrent streams SHALL decrease accordingly. The budget SHALL always permit **at least the foreground stream** to fit, even when a chosen context length is so large that only one stream is affordable; in that case background sessions SHALL wait rather than the system over-committing memory. A session that cannot be admitted in a given step because memory headroom is insufficient SHALL **wait** (remain runnable) rather than be treated as a failure.

#### Scenario: Growing context lowers the affordable stream count
- **WHEN** the user increases the context length
- **THEN** the runtime serves fewer concurrent streams because each stream's key/value cache is larger

#### Scenario: The foreground always fits
- **WHEN** the chosen context length is large enough that only one stream's memory fits
- **THEN** the foreground session is served and background sessions wait, rather than the runtime over-committing memory

#### Scenario: An unadmittable session waits, not fails
- **WHEN** a runnable background session cannot fit in the current step's memory headroom
- **THEN** it waits for a later step and is not reported as a failure

### Requirement: KV-cache quantization, prefix caching, and a rotating fixed-window option
To make long context affordable, the runtime SHALL support **key/value cache quantization** (8-bit and 4-bit), **prefix/prompt caching** of the shared system + skills prefix (computed once and reused across turns and sessions rather than recomputed each turn), and an optional **rotating fixed-window** key/value cache that caps a stream's cache at the most recent window of tokens for unbounded background threads. The per-token cache-size accounting SHALL respect the model's **interleaved sliding-window / global attention**: most layers use a bounded sliding-window cache and a few layers use a full-context (global) cache, and the memory math SHALL sum these per-layer rather than treating every layer as global. The prefix cache SHALL be invalidated when the shared prefix changes.

#### Scenario: The shared prefix is computed once, not per turn
- **WHEN** successive turns of a session share the same system + skills prefix
- **THEN** the prefix's key/value cache is reused and only the turn-specific suffix is prefilled, rather than recomputing the prefix each turn

#### Scenario: Quantized key/value cache reduces per-stream memory
- **WHEN** the compact-context option selects 8-bit key/value caching
- **THEN** each stream's key/value cache occupies less memory, allowing more streams or more context at the same memory budget

#### Scenario: A background thread's cache stays bounded by the rotating window
- **WHEN** a background session runs for many tokens with the rotating fixed-window option
- **THEN** its key/value cache stays bounded to the most recent window rather than growing without limit

#### Scenario: Memory math respects interleaved attention
- **WHEN** the runtime computes a stream's key/value cache size at a context length
- **THEN** it sums the bounded sliding-window layers and the full-context global layers separately rather than treating every layer as full-context

#### Scenario: A changed prefix invalidates the prefix cache
- **WHEN** the shared system + skills prefix changes (for example a skill is enabled mid-session)
- **THEN** the cached prefix is invalidated and re-prefilled once, and subsequent turns reuse the new cached prefix

### Requirement: Growable, user-adjustable context with the cost surfaced
The system SHALL expose the model's maximum context length on the model descriptor and SHALL let the user grow the agent's context length toward that maximum, **clamped to it**. The chosen context SHALL be adjustable via **presets** (a balanced default, a long option, and a maximum option) plus a **"compact long contexts" (8-bit key/value)** toggle, and the system SHALL **surface the cost** of the choice — the estimated memory footprint, the resulting concurrent-stream count, and a relative speed note — so the user sees the RAM/speed trade-off rather than silently running out of memory or thrashing. The system SHALL support a **global default** context length and a **per-skill override** for heavy skills (the effective budget being the larger of the two, clamped to the model maximum). The effective context budget SHALL be supplied to the conversation runtime's compaction trigger through the injected budget provider, so the compaction threshold and the user-chosen context length never disagree.

#### Scenario: Context is clamped to the model maximum
- **WHEN** the user selects the maximum context preset
- **THEN** the effective context length equals the model's architectural maximum and never exceeds it

#### Scenario: The cost of a context choice is shown
- **WHEN** the user changes the context preset or the compact-context toggle
- **THEN** the surface shows the estimated memory footprint, the resulting concurrent-stream count, and a relative speed note for that choice

#### Scenario: A heavy skill raises the effective context
- **WHEN** a session is driven by a skill that declares a larger context need than the global default
- **THEN** the effective context budget for that session is the larger of the two, clamped to the model maximum

#### Scenario: The context choice feeds the compaction trigger
- **WHEN** the user grows the context length
- **THEN** the conversation runtime's compaction trigger reads the larger budget through the injected provider, so old turns are kept verbatim longer before being summarized

### Requirement: Subagents as a fixed-pattern context-hygiene primitive
The system SHALL provide a **subagent** primitive that runs a bounded sub-task in a **fresh** conversation context (its own system prompt, an empty history, and a bounded turn count) and returns **only a summary** to the orchestrating session, so the orchestrator's context stays lean and never absorbs the sub-task's intermediate turns. The subagent primitive SHALL be a **fixed pattern** invoked by name from a registered set with an input, and SHALL NOT be an open-ended, model-driven, recursively self-spawning mechanism. A subagent SHALL be invokable as a routed tool step, and SHALL run as an ordinary batched stream (sharing the single weight read) rather than as its own independent weight read.

#### Scenario: A subagent returns only a summary
- **WHEN** a subagent completes its sub-task
- **THEN** the orchestrating session receives only the subagent's summary, and the subagent's intermediate turns are not added to the orchestrator's context

#### Scenario: A subagent runs in a fresh, bounded context
- **WHEN** a subagent is invoked
- **THEN** it runs in a fresh conversation with an empty history and a bounded turn count, isolated from the orchestrator's history

#### Scenario: Subagents are fixed-pattern, not open-ended spawning
- **WHEN** the orchestrator needs a sub-task run
- **THEN** it invokes a named subagent from the registered set with an input, rather than the model dynamically deciding to recursively spawn arbitrary subagents

#### Scenario: A subagent shares the single weight read
- **WHEN** a subagent runs alongside other sessions
- **THEN** it occupies a batch slot served by the same single weight read, rather than triggering an independent weight read
