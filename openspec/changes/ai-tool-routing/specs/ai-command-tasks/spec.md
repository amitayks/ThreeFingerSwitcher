## ADDED Requirements

### Requirement: Model-driven tool routing via a structured route turn
The system SHALL allow the **model** to select which task ("tool") to run from a turn of conversation, using the existing schema-targeted **structured-output** mechanism as the router — NOT native function-call tokens. A **route turn** SHALL be a `structured(...)` call against a fixed route schema that returns either a chosen tool with its arguments, or an explicit "no tool" decision (a plain text answer). The route turn SHALL inherit structured output's bounded repair/retry and first-class decline: a declined route, an empty-tool route, an unknown tool name, or an exhausted-repair route SHALL all resolve to a **plain text answer**, and SHALL NEVER fabricate or dispatch a tool call. The system SHALL NOT depend on hard token-level function-call caging to obtain the routing decision.

#### Scenario: Route turn selects a tool
- **WHEN** a conversational turn is best served by a task (e.g. "add this to my calendar")
- **THEN** the route turn returns the matching tool and its arguments, and that tool is run

#### Scenario: No tool is needed (plain answer is first-class)
- **WHEN** a conversational turn needs no task (e.g. an ordinary question)
- **THEN** the route turn returns "no tool" (an empty tool or a decline) and the system answers directly without running any task

#### Scenario: A malformed or unknown route never fabricates a tool call
- **WHEN** the route turn's repair/retry loop is exhausted, declines, or names a tool that is not a candidate
- **THEN** the system falls back to a plain text answer and dispatches no side effect

### Requirement: A routed tool reuses the existing task machinery
A tool the model routes to SHALL be a `TaskKind`-shaped capability, and running it SHALL reuse the existing task pipeline **wholesale** — the same `prepare` (schema-targeted, validated, repairable, declinable structured output), the same action `review` (fields + payload), and the same `execute` (the side-effect sink) the user-driven path uses. The model SHALL only choose the tool (and inherit its authored configuration — the project / tool / destination); the tool's own schema SHALL remain the authority that validates the action, so the router's arguments are a hint, never an unvalidated side effect.

#### Scenario: Routed calendar tool runs through the existing prepare/review/execute
- **WHEN** the model routes a turn to the "add to calendar" tool
- **THEN** the task's existing structured-output prepare produces a validated event review, and (after gating) the existing execute creates the event — no separate dispatch path is used

#### Scenario: A routed tool's configuration is not invented by the model
- **WHEN** the model routes to a "save to project" or "send to destination" tool
- **THEN** the target project / destination comes from the tool's authored configuration, not from the model, and the tool's schema validates the content the model produced

#### Scenario: A routed tool that cannot produce a valid action does not fire
- **WHEN** a routed tool's structured prepare exhausts repair without a valid action
- **THEN** no side effect fires and the step is reported as unavailable, fed back so the model may continue

### Requirement: Per-step write-policy gating (read-only auto-runs; side-effecting waits for approval)
Each tool SHALL declare a **write-policy tier** (auto / confirm / dangerous). A routed step whose effective tier is **auto** (read-only or whitelisted) SHALL run without an extra confirmation; a step whose tier is **confirm** or **dangerous** SHALL pause as an **awaiting-approval** step that surfaces the action review, and SHALL apply its side effect only on an explicit approval. The approval SHALL reuse the canonical two-finger compass — **DOWN = approve / RIGHT = skip** — mirroring the existing commit/discard resolution. A skipped step SHALL apply no side effect and SHALL be fed back so the model may continue; a discarded session SHALL apply no side effect.

#### Scenario: Read-only step runs without confirmation
- **WHEN** the model routes to a read-only (auto-tier) tool
- **THEN** the step runs immediately and its result is fed back into the loop without a confirmation pause

#### Scenario: Side-effecting step waits for a DOWN approval
- **WHEN** the model routes to a side-effecting (confirm/dangerous) tool and its action review is ready
- **THEN** the step pauses showing the review, and the side effect fires only when the user approves with a DOWN swipe

#### Scenario: A skipped step applies nothing and the loop continues
- **WHEN** the user skips an awaiting-approval step with a RIGHT swipe
- **THEN** no side effect fires, the step is reported skipped, and the model continues with that outcome

#### Scenario: A side effect that did not land is a failure, never a false success
- **WHEN** an approved (or auto) step's side effect throws when executed
- **THEN** the step is reported failed with a clean headline, never reported done

### Requirement: Bounded multi-hop agent loop
The system SHALL run a **bounded** route → execute → continue loop: it routes a turn, runs the chosen tool, appends the tool result as a turn, and re-routes — up to a hard **step cap**. The loop's running plan (each step's rationale and outcome) SHALL be surfaced live through the existing reasoning ("thinking") channel and SHALL NOT be committed as the answer. The loop SHALL detect **no progress** — a repeated identical routed call, or repeatedly re-routing to a tool that just declined/failed — and terminate with a best-effort final answer rather than spinning. Every termination (answer, cap reached, no-progress, failure) SHALL produce an observable outcome with a clean message; the loop SHALL NEVER end silently.

#### Scenario: Multi-hop plan runs within the step cap
- **WHEN** a turn needs several tools in sequence
- **THEN** the loop runs each in turn, feeding each result back, and stops at or before the hard step cap

#### Scenario: Running plan is shown in the thinking channel
- **WHEN** the loop routes and runs steps
- **THEN** the step rationales and outcomes appear in the collapsible thinking section, while only the final answer is committed

#### Scenario: No-progress loop is guarded
- **WHEN** the model re-routes to the same call (or re-tries a just-failed tool) without progress
- **THEN** the loop terminates with a best-effort final answer summarizing what it did, rather than repeating indefinitely

#### Scenario: Cap reached terminates cleanly
- **WHEN** the loop reaches the hard step cap
- **THEN** it stops and streams a best-effort answer noting the cap, never silently truncating

### Requirement: Candidate tool retrieval (never all tools in front of the router)
The route turn SHALL be offered only a small **candidate** set of tools (about three to five), selected by cheap name/summary/keyword matching against the turn, rather than the entire tool registry. The candidate-selection shape SHALL be the SAME retrieval contract shared with skills and memory (a table-of-contents of summaries with on-demand expansion), so there is one ranking/IO path. The model SHALL be able to request a **wider** candidate set as itself a routed tool step when the offered candidates do not fit.

#### Scenario: Router sees a small candidate set
- **WHEN** a turn is routed
- **THEN** only a handful of relevant candidate tools (with their summaries and argument schemas) are presented to the route turn, not the full registry

#### Scenario: The model can widen the candidate set
- **WHEN** the offered candidates do not fit the turn
- **THEN** the model may route to a "widen candidates" tool step, and the next route turn is offered a broader set

#### Scenario: Skill-allowed tools are always candidates
- **WHEN** a skill is driving the session and declares allowed tools
- **THEN** those tools are included among the route turn's candidates regardless of lexical match

## MODIFIED Requirements

### Requirement: Action review before side effects (default on, user-overridable)
A side-effecting task SHALL present an **action-review preview** (the concrete fields that will be applied) before it executes **when the command's `confirmBeforeRun` is enabled**, and `confirmBeforeRun` SHALL **default to enabled** for side-effecting tasks. The user MAY disable it per command; when disabled, the task commits without the extra action-review step (the baseline deliberate commit still applies). Discarding SHALL always cancel the task with no side effect. The SAME action-review preview and confirmation SHALL back a **model-routed** side-effecting step: a routed step whose effective write-policy requires confirmation SHALL surface the action review as an awaiting-approval step resolved by **DOWN = approve / RIGHT = skip**, and a routed step whose effective write-policy is **auto** (read-only / whitelisted) MAY run without the extra confirmation while still being recorded — so the review contract is shared between the user-driven and model-driven paths, not duplicated.

#### Scenario: Action is shown before it fires (default)
- **WHEN** a calendar/save/open/send task whose command has `confirmBeforeRun` enabled has produced its parsed action
- **THEN** the user sees the action's fields and nothing is applied until they commit

#### Scenario: Confirmation defaults on for side-effecting tasks
- **WHEN** a side-effecting command is created without an explicit choice
- **THEN** its `confirmBeforeRun` defaults to enabled

#### Scenario: User may disable review for a trusted task
- **WHEN** the user disables `confirmBeforeRun` on a side-effecting command and commits it
- **THEN** the task executes its side effect without the extra action-review step, honoring the stored value

#### Scenario: Discard cancels with no effect
- **WHEN** the user discards a task before committing
- **THEN** no event is created, no file is written, no tool is opened, and nothing is sent

#### Scenario: A model-routed side-effecting step reuses the same review
- **WHEN** the model routes to a side-effecting tool whose effective write-policy requires confirmation
- **THEN** the same action-review preview is shown as an awaiting-approval step and the side effect fires only on a DOWN approval (a RIGHT skip applies nothing)
