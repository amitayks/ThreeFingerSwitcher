# ai-parked-sessions — delta for refactor-park-and-background-agents

## MODIFIED Requirements

### Requirement: Lifecycle — max parked count, idle-timeout sleep, and discard semantics
The system SHALL bound and age notch sessions:
- A configurable **maximum parked count** SHALL be enforced by evicting the **least-recently-updated idle** session when the count is exceeded; an **active**, **needs-you**, or actively-**thinking** session SHALL NEVER be evicted.
- **A settled conversational turn is NEVER terminal:** a session whose assistant turn completes while backgrounded SHALL become **idle with an unseen-result badge** — there SHALL be no "terminal completion" classification and no state that auto-dismisses a session because its turn finished. A turn that completes while its session is **expanded** leaves the session active in place (the user is reading it).
- **Expiry is opt-in and protects unseen work:** the **auto-dismiss countdown** SHALL default to **0 = never** (no session expires by age out of the box). When the user configures a positive countdown, a session SHALL be auto-dismissed only when it is **idle** (never active, needs-you, parked-with-pending-work, or thinking), has **no unseen results** (a zero badge — unseen results protect a session from expiry indefinitely), and its idle age exceeds the countdown. Auto-dismissal SHALL route through the same authoritative discard path as a manual deletion.
- **Deletion (discard)** SHALL cancel the session's pending generation via task cancellation (a cancellation is **not** a failure and SHALL NOT leave a failed badge) and remove its durable conversation. **Completed side effects SHALL NOT be rolled back** — work the session already committed (a written event, a moved file, a launched process) stays done; discard stops only future work. Deletion SHALL be reachable from the session's rail card and from its expanded conversation view.
- **No other removal path exists:** user deletion/purge, the opt-in expiry above, and the max-parked eviction SHALL be the ONLY operations that remove a session.

#### Scenario: Exceeding the max evicts an idle session, never an active one
- **WHEN** the parked count exceeds the maximum and at least one idle session exists
- **THEN** the least-recently-updated idle session is evicted and no active, needs-you, or thinking session is evicted

#### Scenario: A docked session's finished answer never dismisses it
- **WHEN** a session is collapsed mid-generation and its assistant turn later completes in the background
- **THEN** the session becomes idle with an unseen-result badge, remains on the rail and in the durable store, and no auto-dismiss occurs because the turn finished

#### Scenario: No session expires at the default countdown
- **WHEN** the auto-dismiss countdown is at its default of 0
- **THEN** no session is ever dismissed by age, regardless of how long it idles

#### Scenario: Unseen results protect a session from a configured countdown
- **WHEN** a positive countdown is configured and an idle session with a non-zero unseen-result badge exceeds that age
- **THEN** the session is NOT dismissed; only an idle session with a zero badge past the countdown is dismissed, through the authoritative discard path

#### Scenario: Discard cancels pending work but does not undo completed side effects
- **WHEN** the user deletes a session that has pending generation and an already-completed side effect
- **THEN** the pending generation is cancelled (not marked failed) and the session is removed, while the completed side effect remains and is not rolled back

### Requirement: Per-card state badges reflect each parked session's state
Each parked session SHALL carry an observable state — **thinking**, **done**, **needs-you**, or **failed** — and the rail card for that session SHALL render a badge reflecting it. The **done** badge SHALL show the count of unseen results. The **failed** badge SHALL carry only a clean, user-facing headline (from the single error translator); raw error text SHALL appear only behind an opt-in disclosure in the **expanded conversation panel**, never in the badge. A side effect that did not land SHALL surface as **failed**, never a false "done." The state SHALL be driven by the scheduler's advance feedback and the routing loop's observable state. A session **collapsed while its turn is in flight** SHALL surface honestly on the rail: a detached **streaming** turn shows the **thinking** badge; a detached turn **paused at an approval** shows the **needs-you** badge.

#### Scenario: A generating session shows the thinking badge
- **WHEN** a parked session is being advanced in the background, or a session was collapsed while its turn was still streaming
- **THEN** its card shows the thinking badge

#### Scenario: A completed session shows an unseen-result count
- **WHEN** a parked session produces a new result the user has not seen
- **THEN** its card shows a done badge with the unseen-result count

#### Scenario: A session docked at an approval shows needs-you
- **WHEN** a session is collapsed while its routing loop is paused awaiting an approval decision
- **THEN** its card shows the needs-you badge and the session is protected from expiry and eviction

#### Scenario: A failed step shows a clean headline, never raw text
- **WHEN** a parked session's step fails
- **THEN** its card shows a failed badge carrying a clean headline only, and any raw detail is hidden behind an opt-in disclosure in the expanded conversation panel

### Requirement: A card expands in place into a notch-anchored conversation panel
Clicking a session card (or creating a new chat) SHALL expand the notch panel **in place** into a conversation view for that session — the same merged-notch panel and chrome, mode-switched from the rail, never a second panel. The expanded view SHALL render the session's thread (user and assistant turns, with the assistant's reasoning behind a collapsible section and streaming shown live), the ordered tool steps the routing loop has run, and a typed **composer**: Enter sends the turn; the panel SHALL become the **key window only while the composer field is focused** so keystrokes reach it, SHALL never become the main window, SHALL never activate the app, and SHALL drop key status when the conversation collapses so the previously frontmost app keeps focus. When the session's routing loop pauses awaiting a decision, the expanded view SHALL present the review as a card with explicit **Approve** and **Skip** buttons (the notch is a cursor-and-keyboard surface; the launcher's two-finger compass grammar is not imported). Each assistant answer SHALL offer a **Copy** affordance (the notch surface writes nothing into other apps). Exactly **one** session SHALL be expanded (foreground) at a time; expanding another card SHALL first collapse the current one. **Collapse** — via an explicit collapse affordance, Escape from the composer, or clicking the notch resting zone — SHALL persist the conversation back to the store, return the panel to rail mode, and hand the session back to background scheduling **without cancelling an in-flight turn** (the turn completes in the background and updates the card's badge). **An in-flight turn INCLUDES one paused at an approval:** collapsing while the routing loop awaits an Approve/Skip decision SHALL keep the suspended step alive (the session surfaces as needs-you), and re-expanding SHALL re-present the same approval card whose Approve/Skip resumes the original paused step — the turn is never restarted or silently dropped by a dock/expand round-trip. While a conversation is expanded, cursor departure SHALL NOT dismiss the panel (the grace-dismiss applies to rail mode only); feature-off and Space-switch teardown SHALL remain synchronous.

#### Scenario: Expanding a card shows its thread and composer in place
- **WHEN** the user clicks a parked session's card on the rail
- **THEN** the same notch panel expands in place into that session's conversation view — thread, tool steps, and composer — with no second panel and no surface change

#### Scenario: The panel is key only while the composer is focused
- **WHEN** the user focuses the composer, types a turn, and later collapses the conversation
- **THEN** keystrokes reach the composer while it is focused (the panel is key), the panel never becomes main and never activates the app, and on collapse key status is dropped so the previously frontmost app keeps focus

#### Scenario: Enter sends and the assistant streams in place
- **WHEN** the user types a message in the expanded composer and presses Enter
- **THEN** the turn is appended to the session's conversation and the assistant's reply streams live into the thread, with reasoning behind the collapsible section

#### Scenario: A paused tool step is resolved with buttons
- **WHEN** the expanded session's routing loop pauses awaiting a confirm/dangerous decision
- **THEN** the review is presented as a card with Approve and Skip buttons, and choosing one resumes the loop accordingly

#### Scenario: Collapse returns the session to background scheduling mid-turn
- **WHEN** the user collapses the conversation while an assistant turn is still streaming
- **THEN** the panel returns to rail mode, the in-flight turn is not cancelled, and its completion updates the session's card badge through the scheduler — the session is NOT dismissed when the turn completes

#### Scenario: Docking a paused approval survives the round-trip
- **WHEN** the user collapses the conversation while the routing loop is paused awaiting an approval, then later re-expands the session and chooses Approve
- **THEN** the suspended step resumes exactly where it paused (the turn is not restarted), and the loop continues to completion

#### Scenario: An expanded conversation does not grace-dismiss on cursor leave
- **WHEN** a conversation is expanded and the cursor moves away from the notch area
- **THEN** the panel stays open (the grace-dismiss applies only to rail mode), and it closes only via an explicit collapse, feature-off, or synchronous teardown paths

### Requirement: One active generation now, with a K-ready scheduler seam for batching
The system SHALL schedule parked sessions through a pure scheduler seam that decides which session each generation slot serves. The seam SHALL expose a slot-count-parameterized request for runnable sessions, an advance-feedback callback, and an escalation callback. In this capability exactly **one** generation SHALL be active and the rest SHALL be queued; the scheduler's runnable-set request SHALL honor the caller's slot count so that a later **batched** runtime can fill **K** slots at once as a **drop-in** with **no change** to the seam. Runnable sessions SHALL exclude those blocked on the user (needs-you) and those whose scheduled next-run time has not arrived; a parked session's next-run time SHALL be **optional**, and a parked session with **no scheduled next-run time is dormant** (blocked on the user or awaiting reactivation) and SHALL NOT be runnable. Runnable sessions SHALL be ordered deterministically (oldest-waiting first). The scheduler SHALL be pure — time SHALL be an input — so its decisions are deterministically testable. The foreground active session SHALL always be served (the scheduler fills only the remaining slots).

#### Scenario: Exactly one parked session is advanced at a time in this capability
- **WHEN** several sessions are parked and runnable and one generation slot is requested
- **THEN** the scheduler returns exactly one session, the oldest-waiting runnable one, and the rest stay queued

#### Scenario: The seam serves K slots without changing
- **WHEN** a batched runtime requests up to K runnable sessions through the same seam
- **THEN** the scheduler returns up to K runnable sessions with no change to the seam's shape (batching is a drop-in)

#### Scenario: Sessions blocked on the user, scheduled later, or dormant are not runnable
- **WHEN** a session is in needs-you, its next-run time has not yet arrived, or it is parked with no scheduled next-run time
- **THEN** the scheduler does not include it in the runnable set

#### Scenario: Scheduling decisions are deterministic
- **WHEN** the scheduler is asked for runnable sessions with a given timestamp
- **THEN** its result depends only on the parked set and that injected timestamp, so it is reproducible in tests

## ADDED Requirements

### Requirement: A background driver advances runnable sessions
The system SHALL actually drive the scheduler seam: on a coarse repeating tick (and once after launch normalization), the driver SHALL request the runnable set (one slot in this capability), rebuild a detached engine from the durable conversation, mark the served session's next-run time cleared (so a second tick cannot double-serve it), and advance the session by running its **pending turn** — the stored conversation whose last message awaits an assistant reply — through the same turn machinery, settle path, and badge classification as a collapsed foreground turn. The driver SHALL skip its pass entirely while any turn is in flight (the foreground or a detached turn owns the single slot). A failed advance SHALL report through the scheduler's advance-feedback callback (re-parking with a scheduled retry), never silently; a completed advance SHALL leave the session idle with an unseen-result badge.

#### Scenario: A recovered session advances in the background
- **WHEN** a parked session is runnable (its scheduled next-run time has arrived) and no turn is in flight
- **THEN** the driver rebuilds its engine from the durable conversation, runs the pending turn detached, and the settled answer leaves the session idle with an unseen-result badge

#### Scenario: The driver never double-serves or preempts
- **WHEN** the driver ticks while a foreground or detached turn is already in flight, or ticks twice while an advance is running
- **THEN** it serves no session (the in-flight turn owns the slot) and the advancing session is not served a second time

#### Scenario: A failed advance re-parks with a retry, never silence
- **WHEN** a background advance fails
- **THEN** the failure reports through the advance-feedback callback, the session re-parks with a scheduled retry, and the rail reflects the state — the session is not dismissed and the failure is not silent

### Requirement: Relaunch normalizes rows and recovers interrupted turns
At startup, the system SHALL normalize the durable rows so no session is stranded: a row persisted as **active** (the app quit while the session was expanded or its turn was detached in flight) SHALL become **parked and scheduled to run now** when its conversation's last message awaits an assistant reply (so the background driver re-runs the interrupted turn), and **idle** otherwise; a **needs-you** row SHALL stay needs-you (blocked on the user, not runnable); a row persisted under the retired terminal state by an older build SHALL decode as **idle** (never dropped, never dismissed). Re-running a recovered turn MAY re-execute auto-tier tool steps (audited, restore-era convention); confirm/dangerous steps still gate.

#### Scenario: A quit mid-response resumes after relaunch
- **WHEN** the app quits while a session's assistant turn is streaming and the app later relaunches
- **THEN** the session's row is normalized to parked-and-scheduled, the background driver re-runs the pending turn, and the answer lands as an unseen result — the session is never left permanently stuck or deleted

#### Scenario: Stale rows never strand or vanish
- **WHEN** the store loads rows persisted as active with no pending turn, as needs-you, or under the retired terminal state
- **THEN** they normalize to idle, stay needs-you, and decode as idle respectively — every previously stored session is still present after relaunch
