## MODIFIED Requirements

### Requirement: Append-only audit log of background actions
The system SHALL keep an **append-only audit log** in which **every** agent tool step writes one record — auto, confirmed, declined, escalated, or failed. Each record SHALL carry the session id, the tool name, the **effective tier** the step ran at, a **redacted, short arguments summary** (never raw secrets or full bodies), the outcome (reusing the tool-step status, a failure carrying a clean headline only), a `wasBackground` flag, and a timestamp. The log SHALL be **viewable** both in the notch rail drop-down and on the Hub AI page as a reverse-chronological "what did my agents do while I was away" ledger. Writing a record SHALL be **non-blocking** and SHALL NOT throw into the agent loop; a persistence failure SHALL be surfaced bounded and non-blocking, never as an app-modal alert, and SHALL NOT lose the in-memory record or stop the running step.

The ledger SHALL support exactly **one removal operation**: an explicit, **user-initiated per-session purge** (the purge-delete gesture on that session's expanded conversation — see `ai-parked-sessions`), which removes every record attributed to that session id from the in-memory ring **and** the durable file. Nothing else SHALL remove or edit records (the bounded cap's oldest-first trimming aside): no agent, tool, or background process can invoke the purge, so the model can never erase its own tracks — only the user's deliberate gesture can. A purge SHALL be non-blocking like a write; a persistence failure during the file rewrite SHALL surface on the same bounded, non-blocking channel as a write failure while the in-memory ring remains purged.

#### Scenario: Every background action is recorded
- **WHEN** a parked agent runs, declines, escalates, or fails a tool step
- **THEN** one record is appended with the tool, effective tier, redacted args, outcome, `wasBackground=true`, and a timestamp

#### Scenario: Arguments are redacted, failures carry a clean headline
- **WHEN** a step's arguments contain a long body or an embedded secret, or the step fails
- **THEN** the record's arguments summary is short and redacted (no raw secret), and a failure stores only the clean headline, not raw OS error text

#### Scenario: The ledger is viewable in the notch and the Hub
- **WHEN** the user opens the notch rail drop-down or the Hub AI page after the agent worked in the background
- **THEN** the recent records appear in reverse-chronological order, distinguishing background actions from foreground ones

#### Scenario: An audit persistence failure does not break the agent
- **WHEN** persisting the audit log to disk fails
- **THEN** the running step is unaffected, the record stays in the in-memory log, and the failure is shown as a bounded non-blocking banner (never an app-modal alert)

#### Scenario: A user purge removes one session's records everywhere
- **WHEN** the user purge-deletes a session
- **THEN** every audit record attributed to that session id disappears from the in-memory ring and the durable file, and records of other sessions are untouched

#### Scenario: Only the user can purge
- **WHEN** any agent tool step, background runner, or automated process executes
- **THEN** it has no path to remove or edit audit records — the purge is reachable only from the user's explicit gesture
