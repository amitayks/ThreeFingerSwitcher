## ADDED Requirements

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

## MODIFIED Requirements

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
