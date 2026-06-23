## MODIFIED Requirements

### Requirement: Swappable model runtime abstraction
The system SHALL access all language-model functionality through a single `LLMRuntime` abstraction that exposes the runtime's capabilities (at least `text`, `vision`; later `audio`), a streaming **single-prompt** text-generation call, a streaming **multi-turn conversation** call that accepts a role-tagged message list, and a structured-output call that returns a typed, schema-validated value. Feature code (the band, the executor, the tasks) SHALL depend only on this abstraction and SHALL NOT reference any concrete model or framework directly, so that an additional model (another Gemma 4 size, a future Gemma, Apple Foundation Models, or a cloud model) can be added later as one new conformer without changing feature code. The multi-turn conversation call SHALL be **additive**: it SHALL be default-implemented in terms of the single-prompt call (flattening the message list into one prompt) so that every existing conformer keeps working unchanged, while a conformer MAY override it to reuse the model's key/value cache across turns.

#### Scenario: Feature code is model-agnostic
- **WHEN** the band executor needs a result
- **THEN** it calls the `LLMRuntime` abstraction and never a concrete model type

#### Scenario: Adding a model is additive
- **WHEN** a new model conformer is introduced
- **THEN** it can be selected without modifying the band, executor, or task code

#### Scenario: The conversation call is additive over the single-prompt call
- **WHEN** an existing conformer that implements only the single-prompt generation call receives a multi-turn conversation request
- **THEN** the default conversation behavior assembles the message list into one prompt and serves it through the single-prompt call, so the conformer needs no change to participate in conversations

## ADDED Requirements

### Requirement: Canonical multi-turn conversation types
The system SHALL define one canonical set of conversation value types — a role-tagged **message** (user/assistant/system/tool), a stable **session identity**, a **conversation** (an ordered message list with a title and timestamps), and a **turn** (the per-generation unit) — in the MLX-free core so that every part of the AI feature (the runtime, the executor, tool routing, parked sessions, memory, and the conversational canvas) shares the same shapes rather than inventing conflicting ones. A message SHALL carry its committed text separately from the model's reasoning text, so that reasoning is structurally distinguishable from re-fed content. The session identity SHALL be stable across stashing and restoring a conversation. These types SHALL be encodable for durable storage (owned by the parked-sessions capability) without this capability owning the store.

#### Scenario: One conversation type is shared across the feature
- **WHEN** any AI subsystem (runtime, executor, routing, parked sessions, memory, canvas) needs a message or a conversation
- **THEN** it uses the single canonical message/conversation/session-identity types rather than a locally-defined shape

#### Scenario: Committed text and reasoning are separable on a message
- **WHEN** a message is constructed for an assistant turn that reasoned before answering
- **THEN** its committed-text field holds only the answer and its reasoning field holds the thinking, so the two never conflate

#### Scenario: Session identity survives a stash and restore
- **WHEN** a conversation is stashed and later restored
- **THEN** it keeps the same session identity so every subsystem still refers to the same session

### Requirement: Multi-turn session with channel-honest history
The executor SHALL evolve from a one-shot single-prompt fire into a multi-turn **session**: it SHALL hold the conversation history, append the user turn and the assistant turn, and continue the thread across turns. When appending the assistant turn, the executor SHALL store **only the response-channel** text as the turn's committed/re-fed content and SHALL store the thinking-channel text on the turn for **display only** — the thinking SHALL NEVER be re-fed into the model's context on a later turn. Assembling the context for a turn SHALL read each message's committed text only, so a turn's reasoning can never bloat the context window. The evolution SHALL be additive: the existing one-shot preset-command path and its states SHALL be preserved unchanged, and new session states (an in-flight conversing turn and an idle awaiting-next-turn state) SHALL be added alongside them.

#### Scenario: A turn is appended to the running thread
- **WHEN** an assistant turn finishes generating within an open conversation
- **THEN** the assistant message is appended to the history and the session becomes ready for the next turn

#### Scenario: Thinking is excluded from re-fed history
- **WHEN** a later turn's context is assembled from the conversation history
- **THEN** only each prior turn's committed response text is included and no prior turn's thinking text appears in the assembled context

#### Scenario: A later turn sees earlier turns
- **WHEN** the user sends a second turn in an open conversation
- **THEN** the assembled context for that turn contains the prior user and assistant turns' committed text

#### Scenario: The one-shot path is preserved
- **WHEN** a preset single-shot command is fired as before
- **THEN** it streams and commits exactly as it did prior to the session evolution, with its existing states unchanged

### Requirement: Seed becomes the first turn
A conversation SHALL be opened from a **seed** — acquired input text and/or a per-turn image — that becomes the conversation's first user turn, assembled from the same input acquisition and prompt-template resolution the one-shot path uses. When the seed has neither non-empty text nor an image, the system SHALL surface the existing "no input" state and SHALL NOT open a conversation or invoke the model.

#### Scenario: A text seed opens turn one
- **WHEN** a conversation is started from acquired input text
- **THEN** the conversation's first message is a user turn carrying that resolved text

#### Scenario: An image seed opens turn one
- **WHEN** a conversation is started from a captured or clipboard image
- **THEN** the conversation's first user turn carries that image as its per-turn image

#### Scenario: An empty seed opens no conversation
- **WHEN** a seed has empty/whitespace text and no image
- **THEN** the system surfaces "no input" and does not open a conversation or call the model

### Requirement: Per-turn channels, cancellation, and failure
Each turn SHALL stream the model's reasoning and answer as the existing two channels — thinking and response — with the thinking streamed live to the reasoning display and reset at the start of every turn so a new turn never shows the prior turn's reasoning, while only the response accumulates into the committed turn. Each turn SHALL be individually cancellable: discarding a turn mid-flight SHALL stop generation promptly, SHALL append no partial assistant message to the history, and SHALL NOT be treated as a failure. A turn-level error (generation, decode, or a failed compaction summarization) SHALL transition the session to an observable failed state carrying a clean, user-facing headline from the single error translator — never silence and never a false "done."

#### Scenario: Thinking streams live per turn and never commits
- **WHEN** a turn with reasoning enabled streams
- **THEN** its thinking streams to the reasoning display while only its response accumulates into the committed turn, and the next turn starts with the reasoning display cleared

#### Scenario: A discarded turn leaves no partial message
- **WHEN** the user discards a turn before it completes
- **THEN** generation stops, no partial assistant message is added to the history, and the session is not marked failed

#### Scenario: A turn error is observable, not silent
- **WHEN** a turn fails to generate or its compaction summarization fails
- **THEN** the session enters a failed state carrying a clean headline from the single error translator, and the conversation history is not silently dropped

### Requirement: Context compaction by token budget
When the assembled context for a turn approaches a configured token budget, the system SHALL **compact** the conversation: it SHALL keep the most recent turns verbatim and summarize the older turns (and any existing summary) into a single compact summary via a model call, then SHALL replace those older raw turns with that summary, which SHALL be carried into subsequent turns' assembled context as a synthetic prefix turn. The summarization input SHALL exclude reasoning text (only committed text is summarized). The token budget SHALL be read through an **injected provider** rather than a concrete user setting, so that this capability does not depend on the batched-runtime/context capability landing first; the user-adjustable context size and the model's maximum context are owned by the batched-runtime/context capability and supplied through that provider. A compaction whose summarization call fails SHALL be a turn failure and SHALL NOT drop the raw history (so a retry still sees the full thread).

#### Scenario: Old turns collapse into a summary near the budget
- **WHEN** the assembled context for the next turn would approach the token budget
- **THEN** the system summarizes the older turns into a compact summary and drops those raw turns, keeping the most recent turns verbatim

#### Scenario: The summary is carried forward
- **WHEN** a conversation has been compacted
- **THEN** subsequent turns' assembled context includes the compact summary as a prefix in place of the dropped raw turns

#### Scenario: The budget is injected, not hard-wired to a setting
- **WHEN** the compaction logic needs the token budget
- **THEN** it reads the budget through an injected provider, so it builds and runs without depending on the concrete user-facing context-size setting

#### Scenario: A failed summarization does not lose history
- **WHEN** the compaction summarization model call fails
- **THEN** the turn enters the failed state and the raw conversation history is retained for a retry, rather than being dropped

### Requirement: Deterministic multi-turn test runtime
The deterministic test runtime SHALL be scriptable for **multi-turn** conversations so that the full session machine can be exercised under automated tests without a model: it SHALL accept an ordered sequence of per-turn scripts (each with its own response and thinking chunks), serve them one per turn, allow a chosen turn to be cancelled mid-stream or to fail with a typed error, and allow the compaction summarization call's output to be scripted. When its multi-turn script is exhausted, it SHALL fall back to its existing single-generation behavior so existing single-shot tests remain unaffected.

#### Scenario: A full conversation is scripted deterministically
- **WHEN** a test scripts a sequence of per-turn responses (and optionally per-turn thinking)
- **THEN** the runtime serves each turn's script in order so a multi-turn session can be asserted end-to-end

#### Scenario: A scripted turn cancellation or failure is observable
- **WHEN** a test scripts a chosen turn to be cancelled mid-stream or to throw a typed error
- **THEN** the session reflects a benign discard (no partial message, not failed) for cancellation, or a failed state with a clean headline for the error

#### Scenario: Single-shot tests are unaffected
- **WHEN** no multi-turn script is provided
- **THEN** the runtime behaves exactly as its existing single-generation scripting did

### Requirement: Real chat-template assembly is deferred to the model conformer
The core SHALL provide a model-agnostic, deterministic message-list-to-prompt assembler that the default conversation call uses (a role-labeled transcript reading committed text only), and the **real** model-specific chat-template assembly — for the on-device Gemma conformer, its native turn markers and its `enable_thinking` reasoning flag — SHALL be provided by the model conformer's overriding conversation call, not by the core assembler. The core assembler SHALL never read reasoning text, so the default conversation path cannot leak thinking into the prompt.

#### Scenario: The default assembler is model-agnostic and thinking-safe
- **WHEN** the default conversation call assembles a prompt from a message list
- **THEN** it produces a deterministic role-labeled transcript reading only committed text, with no message's thinking included

#### Scenario: The Gemma chat-template lives in the conformer
- **WHEN** the on-device Gemma conformer serves a conversation with reasoning enabled
- **THEN** it builds the model's native chat template (its turn markers and the reasoning flag) in its overriding conversation call rather than relying on the core assembler
