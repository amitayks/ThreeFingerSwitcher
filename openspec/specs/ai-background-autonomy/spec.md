# ai-background-autonomy Specification

## Purpose

Define the trust boundary for agent tool steps that run while a session is parked (in the background): a blast-radius classification (contained / whitelisted / dangerous) over the tool-routing write-policy tiers, a user-visible, user-editable whitelist, the effective-tier resolver wired into the routing seam, an append-only audit log of every background action, and the per-step auto-vs-escalate decision (auto runs in the background; confirm waits parked; dangerous escalates to the foreground needs-you state).
## Requirements
### Requirement: Blast-radius tiers classify every tool's background autonomy
The system SHALL classify every agent tool/sink into one of three **blast-radius tiers**, collapsing onto the existing write-policy tiers (`auto`/`confirm`/`dangerous`, owned by the tool-routing capability):

- **CONTAINED** — the app's own stores (agent memory, project notes) and read-only retrieval. These tools SHALL ship `auto` and SHALL run in the background **even when the session is parked** (still audited).
- **WHITELISTED** — a `confirm` tool whose argument **target** (a path under a trusted prefix, or a command matching a trusted pattern) matches the user whitelist. These SHALL resolve to `auto` **only on a match** (still audited).
- **DANGEROUS** — delete, overwrite an existing file, arbitrary shell, anything off-list, and the Claude-handoff cost. These SHALL ship `dangerous` and SHALL be **foreground-only**: a parked session encountering one SHALL escalate to the needs-you state rather than act in the background.

The whitelist SHALL be able to **lower `confirm` to `auto`** on a match but SHALL **never** lower `dangerous` — a destructive operation is dangerous regardless of where it lands. CONTAINED-ness SHALL be intrinsic to the tool (its shipped `auto` tier), not a whitelist entry, so the app's own stores are auto with an empty whitelist.

#### Scenario: A contained store write runs in the background while parked
- **WHEN** a parked agent runs an agent-memory write or a save-to-project append (CONTAINED)
- **THEN** it executes without confirmation in the background and is recorded in the audit log

#### Scenario: A whitelisted write runs auto; an off-list one does not
- **WHEN** a parked agent runs a `confirm` write whose target matches a whitelist entry
- **THEN** the effective tier is lowered to `auto` and it runs in the background (audited)
- **AND WHEN** the target matches no whitelist entry, the effective tier stays `confirm` and the step does not act in the background

#### Scenario: A dangerous operation is never lowered by the whitelist
- **WHEN** a delete / overwrite-existing / arbitrary-shell tool would write inside a whitelisted folder
- **THEN** its tier remains `dangerous` and it is treated as foreground-only, not auto

### Requirement: A user-visible, user-editable whitelist is the security boundary
The system SHALL provide a **whitelist** the user can view and edit: a list of **trusted folder path prefixes** and a list of **trusted command patterns**. The whitelist SHALL **default empty** for arbitrary entries — a fresh install SHALL trust nothing on the wider filesystem — while the app's **memory store and project-note store SHALL be pre-trusted as CONTAINED** (auto without any whitelist row). Whitelist edits SHALL persist with the same keys/defaults/reset semantics as the other AI opt-ins.

A **path target** SHALL match the whitelist iff its standardized absolute path (with `..`/symlinks resolved before matching) has a trusted prefix at a **path-component boundary**. A **command target** SHALL match iff it matches a trusted pattern as an anchored glob. A target that is both a command and a path SHALL require **both** a command-pattern match and a path-prefix match (the stricter rule wins).

#### Scenario: Default-empty trusts nothing arbitrary
- **WHEN** the whitelist is at its default
- **THEN** no arbitrary path or command is trusted, and only the CONTAINED memory/project stores run auto

#### Scenario: Path matching respects component boundaries and resolves escapes
- **WHEN** a write targets a path that, once standardized, lies under a trusted prefix at a component boundary
- **THEN** it matches the whitelist; a path that only shares a string prefix (e.g. `/Notes2` vs trusted `/Notes`) or that escapes via `..`/symlinks does NOT match

#### Scenario: A command and a path must both be trusted
- **WHEN** a whitelisted command is aimed at a path outside every trusted prefix
- **THEN** the target does not match the whitelist and the step stays `confirm`

#### Scenario: Whitelist edits persist
- **WHEN** the user adds or removes a trusted folder or command pattern
- **THEN** the change persists across launches and is preserved by a reset-to-defaults like the other AI opt-ins

### Requirement: Effective-tier resolution wired into the tool-routing seam
The system SHALL provide the concrete write-policy resolver that the tool-routing loop already injects (the `WritePolicyResolving` seam), replacing the stand-alone descriptor-identity default. The resolver SHALL compute a step's **effective tier** as: the descriptor's own tier, lowered to `auto` **only** when the tool is CONTAINED or its target matches the whitelist, and **never** lowered when the descriptor is `dangerous`. The resolver SHALL satisfy the existing descriptor-only seam method AND offer a target-aware resolution for the routed call's argument target, **without changing the routing protocol**.

#### Scenario: Resolution lowers a matched confirm to auto
- **WHEN** the resolver evaluates a `confirm` external tool whose routed target matches the whitelist
- **THEN** the effective tier is `auto`

#### Scenario: Resolution leaves an unmatched confirm and never lowers dangerous
- **WHEN** the resolver evaluates a `confirm` tool with no matching target, or any `dangerous` tool
- **THEN** the effective tier is `confirm` (unmatched) or `dangerous` (unconditional), respectively

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

### Requirement: A parked agent decides auto vs escalate per step
The system SHALL decide, per tool step, whether a **parked** session acts automatically or escalates, from the step's **effective tier** and the session's park state:

- an `auto` effective tier SHALL **run in the background** and be audited;
- a `confirm` effective tier on a parked session SHALL **wait parked** (resolved later when the session is brought back, via the routing approval gesture DOWN=approve / RIGHT=skip) without escalating;
- a `dangerous` effective tier on a parked session SHALL **escalate to the foreground** by raising the needs-you state (via the parked-sessions scheduler), which surfaces the needs-you badge (rendered by the parked-sessions capability), with a clean one-line reason;
- when the session is **active** (foreground), this decision SHALL defer to the existing routing approval gate (no escalation).

An escalation SHALL be resolved by the user pulling the session back and approving (DOWN), at which point the step proceeds as a foreground step; a skip (RIGHT) SHALL decline it. A session already in needs-you SHALL NOT be double-escalated. A completed side effect SHALL NOT be rolled back — the audit log records it; it is not reversed.

#### Scenario: Auto step runs in the background
- **WHEN** a parked session reaches a step whose effective tier is `auto`
- **THEN** the step runs in the background and is audited, without user attention

#### Scenario: Confirm step waits parked without escalating
- **WHEN** a parked session reaches a step whose effective tier is `confirm`
- **THEN** the step waits in the parked session and is resolved when the user brings the session back, without raising the needs-you state

#### Scenario: Dangerous step escalates to needs-you
- **WHEN** a parked session reaches a step whose effective tier is `dangerous`
- **THEN** the session escalates to the needs-you state with a clean reason, the needs-you badge appears, and the step waits until the user pulls the session back and approves it

#### Scenario: Already-escalated session is not double-escalated
- **WHEN** a session is already in needs-you and another dangerous step arrives
- **THEN** the session is not escalated again (the badge count already reflects the pending attention) and the step is recorded as awaiting approval

