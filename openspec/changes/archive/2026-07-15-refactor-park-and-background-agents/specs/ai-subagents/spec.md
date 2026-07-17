# ai-subagents Specification

## ADDED Requirements

### Requirement: Subagents are fixed, bounded templates — never dynamic spawning
The system SHALL model a subagent as a **named, fixed template** (a system prompt plus a bounded turn budget) drawn from a **small registered set**. There SHALL be NO open-ended, model-invented, or recursive subagent spawning: the model can only invoke the registered templates, a subagent SHALL NOT itself invoke subagents, and the template set SHALL be injectable so it can grow deliberately (e.g. skills-derived later) without changing the seam.

#### Scenario: Only registered templates are invocable
- **WHEN** the routing loop offers tools for a turn
- **THEN** exactly the registered subagent templates appear (as `subagent:<name>` tools), and no path exists for the model to define or spawn an unregistered subagent

#### Scenario: No recursion
- **WHEN** a subagent runs its sub-task
- **THEN** its own execution offers no subagent tools (a subagent cannot spawn subagents)

### Requirement: A subagent runs as a routable tool step in a fresh conversation
Each registered subagent SHALL be exposed to the agent loop as a **routable tool** with an `auto` write policy (CONTAINED — it is read-only with respect to the orchestrator's world; it performs no external side effects in this capability). Invoking it SHALL open a **fresh conversation** — a brand-new session identity seeded with the template's own system prompt and the routed input, empty of the orchestrator's history — and run it on the session's runtime **within the orchestrator's in-flight turn** (same task, same cancellation: cancelling the turn cancels the subagent; no new concurrency surface). The subagent step SHALL be audited like any other tool step.

#### Scenario: A subagent step runs in isolation
- **WHEN** the loop routes a `subagent:<name>` step with an input
- **THEN** the sub-task runs in a fresh conversation seeded only with the template's system prompt and that input — none of the orchestrator's history is visible to it

#### Scenario: Cancelling the turn cancels the subagent
- **WHEN** the user discards the turn while a subagent step is running
- **THEN** the subagent's generation is cancelled with the turn (a cancellation, not a failure)

### Requirement: Only the summary re-enters the orchestrator
A subagent SHALL return **only a summary** to the orchestrator: the step's result carries the sub-task's final text, which re-enters the orchestrator's thread as the tool step's message — the orchestrator's context SHALL NEVER absorb the subagent's intermediate turns, reasoning, or system prompt (the context-hygiene contract that justifies subagents on a single-GPU machine). A subagent failure SHALL surface as a **failed tool step** carrying a clean headline from the shared error taxonomy — never raw error text, never a fabricated summary.

#### Scenario: The orchestrator sees one summary message
- **WHEN** a subagent step completes
- **THEN** exactly one tool message containing the subagent's summary is appended to the orchestrator's context, and none of the sub-conversation's other content appears there

#### Scenario: A subagent failure is a clean failed step
- **WHEN** the subagent's generation fails
- **THEN** the step resolves as failed with a clean translated headline (no raw error text), and the loop handles it like any failed step — never presenting a fabricated summary
