## ADDED Requirements

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
The runtime conformer SHALL accept an image input (e.g. a captured screen region) alongside the text prompt for vision-capable commands, and SHALL produce a text or structured result describing/acting on that image.

#### Scenario: Screen region is interpreted
- **WHEN** a vision command supplies a captured screen region and a prompt such as "what is this?"
- **THEN** the runtime returns a text answer grounded in the image

### Requirement: Model lifecycle management
The system SHALL manage model weights via a lifecycle: weights are downloaded only after the user opts in (a multi-gigabyte, quantized QAT download), the download SHALL be resumable and **integrity-verified** before use, the model SHALL be **lazy-loaded** on first use, **kept resident** between calls to avoid repeated cold loads, and **evicted** on memory pressure or when the opt-in is turned off. While a model is loading, the system SHALL expose a loading state to the UI rather than blocking silently.

#### Scenario: No download until opt-in
- **WHEN** the AI commands opt-in is off
- **THEN** no model weights are downloaded

#### Scenario: Corrupt download is rejected
- **WHEN** a downloaded model fails its integrity check
- **THEN** it is not loaded and the user is told the download must be retried

#### Scenario: Model stays resident between calls
- **WHEN** two commands are run in succession with the model already loaded
- **THEN** the second run does not pay a full cold-load cost

#### Scenario: Loading state is observable
- **WHEN** the model is loading on first use
- **THEN** the preview surface shows a loading state

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
The runtime SHALL target current, high-end Apple Silicon and use the best model the configuration specifies; it SHALL NOT provide a degraded small-model path for low-end hardware in this version. If the hardware or model cannot satisfy the feature, the system SHALL report the feature as unavailable rather than silently running a worse experience.

#### Scenario: Unsupported configuration reports unavailable
- **WHEN** the required model cannot be run on the current machine
- **THEN** the feature reports itself unavailable instead of degrading silently
