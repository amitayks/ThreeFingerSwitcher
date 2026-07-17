# ai-background-autonomy — delta for refactor-park-and-background-agents

## MODIFIED Requirements

### Requirement: A parked agent decides auto vs escalate per step
The system SHALL decide, per tool step, whether a **parked** session acts automatically or escalates, from the step's **effective tier** and the session's park state:

- an `auto` effective tier SHALL **run in the background** and be audited;
- a `confirm` effective tier on a parked session SHALL **wait parked** (resolved later when the session is brought back, via the routing approval affordance) without escalating;
- a `dangerous` effective tier on a parked session SHALL **escalate to the foreground** by raising the needs-you state, with a clean one-line reason;
- when the session is **active** (foreground), this decision SHALL defer to the existing routing approval gate (no escalation).

**A parked wait or escalation SHALL genuinely pause the agent loop:** the loop SHALL end the turn with a distinct **paused-awaiting-user outcome** that appends **no fabricated final answer** and is **never** classified as a completed task — the step is neither run nor skipped, and the session's recorded tool steps show it pending. A **wait-parked** session SHALL become dormant (parked with no scheduled next-run time — not runnable) until the user brings it back. An **escalation SHALL route through the parked-sessions controller seam** (not a raw scheduler mutation) so the needs-you state is **persisted durably and repainted on the rail** — a needs-you raised in the background survives relaunch and is never a silent in-memory flag. An escalation SHALL be resolved by the user pulling the session back and approving, at which point the step proceeds as a foreground step; a skip SHALL decline it. A session already in needs-you SHALL NOT be double-escalated. A completed side effect SHALL NOT be rolled back — the audit log records it; it is not reversed.

#### Scenario: Auto step runs in the background
- **WHEN** a parked session reaches a step whose effective tier is `auto`
- **THEN** the step runs in the background and is audited, without user attention

#### Scenario: Confirm step waits parked without escalating
- **WHEN** a parked session reaches a step whose effective tier is `confirm`
- **THEN** the loop pauses with the paused-awaiting-user outcome (no fabricated answer, not a completed task), the session becomes dormant, and the step is resolved when the user brings the session back — without raising the needs-you state

#### Scenario: Dangerous step escalates to needs-you
- **WHEN** a parked session reaches a step whose effective tier is `dangerous`
- **THEN** the loop pauses with the paused-awaiting-user outcome, the escalation routes through the parked-sessions controller seam so the needs-you badge is persisted and repainted with a clean reason, and the step waits until the user pulls the session back and approves it

#### Scenario: A paused step never fabricates completion
- **WHEN** a parked session's loop pauses on a confirm or dangerous step
- **THEN** no final answer is synthesized for the turn, the outcome is not a completed task, and the session is not dismissed — the pending step is observable state

#### Scenario: Already-escalated session is not double-escalated
- **WHEN** a session is already in needs-you and another dangerous step arrives
- **THEN** the session is not escalated again (the badge count already reflects the pending attention) and the step is recorded as awaiting approval
