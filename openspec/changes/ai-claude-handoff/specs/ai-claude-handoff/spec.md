## ADDED Requirements

### Requirement: Model-callable Claude Code handoff tool
The system SHALL provide a `launch_claude` capability the router can select like any other tool, described by a tool descriptor whose arguments are a starting **prompt** and an optional **folder**. When selected and permitted, the handoff SHALL open Claude Code in that folder with that starting prompt, reusing the existing no-new-permission terminal handoff (the self-deleting `.command` file opened through the system default handler) and SHALL NOT introduce a new launch mechanism or request any new permission (in particular, no Apple Events / Automation grant). A non-empty prompt SHALL start Claude with that prompt as its input; an empty prompt SHALL open a bare Claude session in the folder. When the route omits a folder, the handoff SHALL use the skill's configured default working directory; when neither is available, it SHALL surface a clean, bounded failure and SHALL NOT spawn anything.

#### Scenario: Router selects the handoff and it opens Claude with the prompt
- **WHEN** the router selects `launch_claude` with a folder and a prompt, and the call is permitted
- **THEN** Claude Code opens in that folder started with that prompt, via the existing self-deleting `.command` handoff, requiring no new permission

#### Scenario: Empty prompt opens a bare session
- **WHEN** `launch_claude` is selected with a folder and an empty prompt
- **THEN** a bare Claude session opens in that folder

#### Scenario: Missing folder fails cleanly without spawning
- **WHEN** `launch_claude` is selected with no folder and the skill has no default working directory
- **THEN** nothing is spawned and a clean, bounded failure is surfaced, and no Claude budget is spent

### Requirement: Claude handoff is a dangerous-tier action defaulting to per-call confirmation
The `launch_claude` tool descriptor SHALL always carry the **dangerous** write-policy tier, and the effective gate for a call SHALL be the descriptor tier intersected with the user's whitelist, then narrowed by the skill's confirm mode. The handoff SHALL default to **confirm** (foreground approval per call), because real money is spent. A skill MAY opt into **auto** explicitly in its handoff configuration; the auto opt-in SHALL only downgrade within what the user whitelist permits and SHALL NEVER override a user who has not trusted handoff. Confirmation SHALL reuse the canonical approval gesture (DOWN = approve, RIGHT = skip) when the session is active.

#### Scenario: Handoff defaults to confirm
- **WHEN** a skill triggers `launch_claude` without an explicit confirm mode
- **THEN** the handoff requires a foreground per-call approval before Claude is opened

#### Scenario: A skill opts into auto
- **WHEN** a skill explicitly sets its handoff confirm mode to auto and the user has whitelisted handoff
- **THEN** the handoff runs without a per-call approval (subject to the budget cap and still audited)

#### Scenario: User whitelist overrides a skill's auto
- **WHEN** a skill sets auto but the user has NOT whitelisted Claude handoff
- **THEN** the effective tier stays dangerous and the handoff requires foreground approval (or escalation), regardless of the skill's auto

#### Scenario: Approve and skip use the canonical gesture
- **WHEN** a confirm-mode handoff awaits the user in an active session
- **THEN** a DOWN gesture approves and opens Claude, and a RIGHT gesture skips the handoff with no spend

### Requirement: Budget and rate cap on Claude handoffs
Even an auto handoff SHALL be capped so an autonomous agent loop cannot rack up real spend: the system SHALL enforce a maximum number of handoffs per rolling 24-hour window and a maximum number of concurrent in-flight handoffs, over an append-only spend ledger that survives a relaunch within the window. The cap SHALL use a rolling window keyed off an injected current time, NOT a calendar-day reset. A per-skill cap MAY tighten the cap; a per-skill cap of zero SHALL fall back to the global default. A handoff whose launch fails after a spend was recorded SHALL refund that spend so the cap stays honest. An over-budget call SHALL NEVER be silently dropped.

#### Scenario: Under the cap the handoff is allowed
- **WHEN** the number of handoffs in the last 24 hours is below the cap and concurrency is below its limit
- **THEN** the handoff is allowed to proceed (subject to its confirm/auto gate)

#### Scenario: Rolling window cannot be gamed across midnight
- **WHEN** handoffs are spread across a calendar-day boundary but fall within the same rolling 24-hour window
- **THEN** they are counted together against the cap, with no midnight reset

#### Scenario: Cap survives a relaunch
- **WHEN** the process restarts within the rolling window
- **THEN** prior handoffs inside the window still count against the cap and the budget is not reset

#### Scenario: A failed launch refunds its spend
- **WHEN** a handoff records a spend but its launch then fails
- **THEN** the spend is refunded and the in-flight count is decremented, leaving the cap unchanged

### Requirement: Over-budget auto handoffs degrade, never run unprompted
When an auto handoff is over the budget cap, it SHALL degrade to a foreground per-call confirmation (in an active session) rather than running unprompted, and SHALL escalate to the needs-you badge (in a parked session) — it SHALL NOT auto-run over budget and SHALL NOT be silently dropped. The user, never the loop, SHALL be the only authority that can spend over the cap. The approval surface SHALL indicate that the budget cap has been reached.

#### Scenario: Auto over budget degrades to confirm
- **WHEN** an auto handoff is requested but the daily cap has been reached and the session is active
- **THEN** the handoff degrades to a foreground confirmation that states the budget cap was reached, and it does not auto-run

#### Scenario: Auto over budget in a parked session escalates
- **WHEN** an auto handoff is over budget and the session is parked
- **THEN** the handoff escalates to a needs-you badge for the user to decide, and no spend occurs until the user returns and approves

### Requirement: Every Claude handoff is audited
Every handoff attempt — auto, confirmed, declined, failed, or over-budget — SHALL emit exactly one append-only audit record naming the tool, the dangerous policy tier, a redacted/short argument summary (the folder and a truncated prompt, NEVER the full prompt verbatim), the outcome, whether it ran in the background, and a timestamp. The audit SHALL route into the single shared audit log rather than a separate handoff-only log. Raw prompt text SHALL appear only in logs or behind an opt-in details disclosure, never in the audit summary or any headline.

#### Scenario: A handoff records one audit entry
- **WHEN** any `launch_claude` attempt resolves (done, declined, failed, or over-budget)
- **THEN** exactly one audit record is appended naming the tool, the dangerous tier, the redacted argument summary, the outcome, the background flag, and a timestamp

#### Scenario: The audit summary never carries the full prompt
- **WHEN** an audit record for a handoff is inspected
- **THEN** its argument summary contains the folder and at most a truncated prompt, and the full prompt text is not present

### Requirement: Dangerous handoff escalates from a parked session
A dangerous handoff that needs approval SHALL NOT auto-run and SHALL NOT silently wait inside a parked session — it SHALL raise the needs-you state with a badge so the user is pulled back to approve the spend. An auto handoff that is under budget and explicitly trusted MAY run in the background while parked (still audited), mirroring the autonomy rule that whitelisted/auto writes run when parked while dangerous writes escalate.

#### Scenario: Confirm-mode handoff while parked escalates
- **WHEN** a confirm-mode (or whitelist-dangerous) handoff is requested while the session is parked
- **THEN** the session raises a needs-you badge for the pending handoff and no Claude is opened and no spend occurs until the user returns and approves

#### Scenario: Auto under-budget handoff runs while parked
- **WHEN** an auto handoff that is under budget and within the user whitelist is requested while the session is parked
- **THEN** it opens Claude in the background and is audited, without pulling the user back

### Requirement: V1 handoff is fire-and-forget with a documented round-trip future
Version 1 of the handoff SHALL be fire-and-forget: it SHALL open Claude with the prompt and consider the handoff complete, returning a done result the local agent uses to wind down its own loop, and SHALL NOT capture or consume Claude Code's output. The system SHALL leave a seam so a future version can perform the structured round-trip (consume Claude's result and resume the local conversation) as an additive change, without reworking the handoff tool or the cost gate.

#### Scenario: V1 opens Claude and completes the step
- **WHEN** a permitted handoff launches in v1
- **THEN** the step result is a done outcome summarizing that Claude opened in the folder, and the local agent does not wait for or read Claude's output

#### Scenario: The round-trip is a documented future, not built in v1
- **WHEN** the handoff design is reviewed
- **THEN** v1 does not consume Claude's output, and the seam for a future round-trip (consume the result and resume the conversation) is documented as an additive future

### Requirement: Bounded, non-blocking handoff failure surfacing
Handoff failures SHALL map at the boundary into the handoff error taxonomy and surface bounded and non-blocking — never via an app-modal alert, and never with raw OS or vendor error text in a headline (raw text is allowed only in logs or behind an opt-in details disclosure). A failed launch SHALL become an observable failed step carrying a clean headline (never a false "Done"), and the corresponding spend SHALL be refunded. A handoff disabled for a skill SHALL surface as a clean declined result. A user discard during approval SHALL end the loop quietly with no spend and SHALL NOT be reported as a failure.

#### Scenario: A failed launch surfaces a clean failed step
- **WHEN** opening Claude fails (e.g. the terminal could not be opened or the command file could not be written)
- **THEN** the step is reported failed with a clean headline, the spend is refunded, and no app-modal alert appears

#### Scenario: No raw error text in a headline
- **WHEN** any handoff failure is presented
- **THEN** the headline is a clean, human-readable message and any raw OS/vendor error text appears only in logs or behind an opt-in details disclosure

#### Scenario: Discard during approval is quiet, not a failure
- **WHEN** the user discards the canvas while a handoff awaits approval
- **THEN** the loop ends quietly, no Claude is opened, no spend occurs, and it is not reported as a failure
