## ADDED Requirements

### Requirement: Sessions are born at the notch from the new-chat card
The revealed rail SHALL always include a persistent **"+ New chat"** card — including when no sessions exist (an empty dock still reveals a purposeful surface). Activating it SHALL create a new conversational session **durably at birth**: a fresh conversation with a stable session identity is written to the durable store immediately (so it survives relaunch from its first moment), registered with the scheduler, and expanded in place for typing. The notch SHALL be the **only** surface that creates conversational sessions: the launcher's AI command band never creates, parks, or transfers a session here (quick actions are one-shot and ephemeral — see `ai-command-band`). A session SHALL remain at the notch for its whole life — background-advancing, collapsing, and expanding in place — until it is removed by **expiry** (the auto-dismiss countdown) or **deletion** (discard); there SHALL be no operation that moves it to another surface.

#### Scenario: New chat creates a durable session and expands it
- **WHEN** the user activates the "+ New chat" card on the rail
- **THEN** a new session with a stable identity is written to the durable store immediately, registered with the scheduler, and the panel expands in place ready for the first typed turn

#### Scenario: The new-chat card is present on an empty dock
- **WHEN** the rail is revealed while no sessions exist
- **THEN** the rail shows the "+ New chat" card, and no empty-state dead end is presented

#### Scenario: A session lives only at the notch
- **WHEN** a session exists in the notch dock
- **THEN** every interaction with it (expand, type, approve, collapse, delete) happens on the notch surface, and no affordance moves it onto the launcher canvas or any other surface

### Requirement: A card expands in place into a notch-anchored conversation panel
Clicking a session card (or creating a new chat) SHALL expand the notch panel **in place** into a conversation view for that session — the same merged-notch panel and chrome, mode-switched from the rail, never a second panel. The expanded view SHALL render the session's thread (user and assistant turns, with the assistant's reasoning behind a collapsible section and streaming shown live), the ordered tool steps the routing loop has run, and a typed **composer**: Enter sends the turn; the panel SHALL become the **key window only while the composer field is focused** so keystrokes reach it, SHALL never become the main window, SHALL never activate the app, and SHALL drop key status when the conversation collapses so the previously frontmost app keeps focus. When the session's routing loop pauses awaiting a decision, the expanded view SHALL present the review as a card with explicit **Approve** and **Skip** buttons (the notch is a cursor-and-keyboard surface; the launcher's two-finger compass grammar is not imported). Each assistant answer SHALL offer a **Copy** affordance (the notch surface writes nothing into other apps). Exactly **one** session SHALL be expanded (foreground) at a time; expanding another card SHALL first collapse the current one. **Collapse** — via an explicit collapse affordance, Escape from the composer, or clicking the notch resting zone — SHALL persist the conversation back to the store, return the panel to rail mode, and hand the session back to background scheduling **without cancelling an in-flight turn** (the turn completes in the background and updates the card's badge). While a conversation is expanded, cursor departure SHALL NOT dismiss the panel (the grace-dismiss applies to rail mode only); feature-off and Space-switch teardown SHALL remain synchronous.

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
- **THEN** the panel returns to rail mode, the in-flight turn is not cancelled, and its completion updates the session's card badge through the scheduler

#### Scenario: An expanded conversation does not grace-dismiss on cursor leave
- **WHEN** a conversation is expanded and the cursor moves away from the notch area
- **THEN** the panel stays open (the grace-dismiss applies only to rail mode), and it closes only via an explicit collapse, feature-off, or synchronous teardown paths

## MODIFIED Requirements

### Requirement: Per-card state badges reflect each parked session's state
Each parked session SHALL carry an observable state — **thinking**, **done**, **needs-you**, or **failed** — and the rail card for that session SHALL render a badge reflecting it. The **done** badge SHALL show the count of unseen results. The **failed** badge SHALL carry only a clean, user-facing headline (from the single error translator); raw error text SHALL appear only behind an opt-in disclosure in the **expanded conversation panel**, never in the badge. A side effect that did not land SHALL surface as **failed**, never as a false "done." The state SHALL be driven by the scheduler's advance feedback and the routing loop's observable state.

#### Scenario: A generating session shows the thinking badge
- **WHEN** a parked session is being advanced in the background
- **THEN** its card shows the thinking badge

#### Scenario: A completed session shows an unseen-result count
- **WHEN** a parked session produces a new result the user has not seen
- **THEN** its card shows a done badge with the unseen-result count

#### Scenario: A failed step shows a clean headline, never raw text
- **WHEN** a parked session's step fails
- **THEN** its card shows a failed badge carrying a clean headline only, and any raw detail is hidden behind an opt-in disclosure in the expanded conversation panel

### Requirement: The needs-you escalation raises an ambient, peripheral notch glow
When a parked session escalates to **needs-you** (a dangerous write or required approval surfaced from the background-autonomy capability), the system SHALL signal it **ambiently** with a soft, slow **glow** on the notch home zone — a peripheral cue, **not** an intrusive interruption. The glow SHALL NOT be a modal alert, SHALL NOT play a sound, SHALL NOT bounce, and SHALL NOT steal focus (the panel stays non-activating and never becomes key while unexpanded). The glow SHALL appear **only** while at least one parked session is in needs-you and SHALL **persist** until the user **addresses** every needs-you session (expanding it and resolving its pending decision, or deleting it); merely revealing the rail SHALL NOT clear it. The per-session **count** SHALL live on the card; the zone glow SHALL be a binary present/slow-pulse signal, so an escalation is never silently missable yet never blocks work.

#### Scenario: A background escalation lights the ambient glow
- **WHEN** a parked session escalates to needs-you
- **THEN** the notch home zone shows a soft, slow ambient glow and no modal alert, sound, bounce, or focus-steal occurs

#### Scenario: The glow persists until the escalation is addressed
- **WHEN** the user reveals the rail but does not yet expand-and-resolve or delete the needs-you session
- **THEN** the ambient glow persists, and it clears only once every needs-you session has been addressed

#### Scenario: The glow is absent when nothing needs the user
- **WHEN** no parked session is in needs-you
- **THEN** the notch home zone shows no glow

### Requirement: Cursor-to-notch reveals a scrollable rail of parked sessions
Moving the cursor to the notch home zone SHALL reveal a **rail** of parked-session cards, **always including the persistent "+ New chat" card**. On a notched display the rail SHALL **emerge from the notch as a downward extension** — its top spanning up behind the notch (reaching the physical top), the cards spreading **downward** below the notch; on a notchless/external display the rail SHALL **hang below** the top-center tab. The rail SHALL be **horizontally scrollable** when it overflows. The reveal SHALL reuse the edge-gated cursor-reveal pattern (a passive global cursor monitor needing **no new permission**; geometry read only when the cursor is near the zone while hidden; a unified live area — the zone, the rail, **and the notch band** — with a grace-period dismiss, so moving the cursor **up into the notch docks** rather than dismisses; a coarse re-feed while shown). The grace-period dismiss SHALL apply **only while the panel is in rail mode** (an expanded conversation never grace-dismisses). The panel SHALL **spread** open and closed with a smooth **ease-in-out** animation anchored at its top edge — growing out of the notch on reveal and receding back into it on the grace-dismiss. Teardown for the grace-dismiss MAY defer the order-out until the recede completes, but restore and feature-off teardown SHALL remain **synchronous** (the ghost-on-Space-switch path).

#### Scenario: Cursor near the notch reveals the rail
- **WHEN** the cursor moves to the notch home zone
- **THEN** the rail of parked-session cards — always including the "+ New chat" card — is revealed, emerging downward from the notch on a notched display, or hanging below the tab on a notchless/external display

#### Scenario: The panel spreads open and closed with ease-in-out
- **WHEN** the rail is revealed and later grace-dismissed
- **THEN** it spreads open out of the notch and recedes back into it on a smooth ease-in-out animation anchored at the top edge, and a reveal arriving mid-recede cancels the recede and re-spreads

#### Scenario: The rail scrolls when it overflows
- **WHEN** there are more parked sessions than fit across the rail
- **THEN** the rail scrolls horizontally to reach the rest

#### Scenario: Moving up into the notch docks rather than dismisses
- **WHEN** the rail is shown and the cursor moves up into the notch band above the resting zone
- **THEN** the rail stays shown (the notch band is inside the contiguous live area), and it does not grace-dismiss

#### Scenario: Leaving the zone and rail dismisses after a grace period in rail mode
- **WHEN** the panel is in rail mode and the cursor leaves the zone, the rail, and the notch band for longer than the grace period
- **THEN** the rail dismisses, ordered out synchronously

#### Scenario: The reveal needs no new permission
- **WHEN** the cursor-reveal monitor is installed
- **THEN** it observes cursor moves passively and requires no Input Monitoring or other new permission

### Requirement: Durable parked-session store survives relaunch with a one-line resume
The system SHALL durably persist each parked session's conversation (encodable) keyed by its session identity, plus the lightweight rail/scheduler rows, so that parked sessions and the rail rebuild after relaunch. The store SHALL be the **single** owner of parked-conversation persistence (it does not duplicate the conversation type, which the conversation-runtime capability owns). Because sessions are durable **from birth** (see "Sessions are born at the notch from the new-chat card"), a relaunch SHALL rebuild every session that had not yet expired or been deleted — including one created moments before quit with no completed turn. File and coding failures SHALL be mapped at the store boundary into the capability's error type and surfaced bounded and non-blocking — never a raw thrown error and never silently dropped.

#### Scenario: Parked sessions rebuild after relaunch
- **WHEN** the app relaunches with sessions previously parked
- **THEN** the rail rebuilds from the durable store, each card showing its title and state

#### Scenario: A just-born session survives relaunch
- **WHEN** the user creates a new chat and quits the app before any assistant turn completes
- **THEN** after relaunch the session's card is present on the rail, expandable to its stored conversation

#### Scenario: A store failure is observable, not silent
- **WHEN** persisting or reading a parked session fails
- **THEN** the failure is mapped into the capability's error type and surfaced as a bounded, non-blocking failed indicator, never a raw error and never silence

### Requirement: Lifecycle — max parked count, idle-timeout sleep, and discard semantics
The system SHALL bound and age notch sessions:
- A configurable **maximum parked count** SHALL be enforced by evicting the **least-recently-updated idle** session when the count is exceeded; an **active**, **needs-you**, or actively-**thinking** session SHALL NEVER be evicted.
- **Expiry:** a session whose task reached a **terminal completion** while backgrounded SHALL be auto-dismissed forever on the next pass, and a **non-protected idle** session (parked/idle — never active, needs-you, or thinking) whose idle age exceeds a configurable **auto-dismiss countdown** SHALL be auto-dismissed forever. Auto-dismissal SHALL route through the same authoritative discard path as a manual deletion. A terminal completion that lands while its session is **expanded** SHALL NOT dismiss it out from under the reader: the session instead becomes idle in place and later expires by the countdown like any idle session.
- **Deletion (discard)** SHALL cancel the session's pending generation via task cancellation (a cancellation is **not** a failure and SHALL NOT leave a failed badge) and remove its durable conversation. **Completed side effects SHALL NOT be rolled back** — work the session already committed (a written event, a moved file, a launched process) stays done; discard stops only future work. Deletion SHALL be reachable from the session's rail card and from its expanded conversation view.

#### Scenario: Exceeding the max evicts an idle session, never an active one
- **WHEN** the parked count exceeds the maximum and at least one idle session exists
- **THEN** the least-recently-updated idle session is evicted and no active, needs-you, or thinking session is evicted

#### Scenario: An idle session expires after the countdown
- **WHEN** a non-protected idle session's age since its last update exceeds the auto-dismiss countdown
- **THEN** it is dismissed forever through the authoritative discard path, and no active, needs-you, or thinking session is expired

#### Scenario: A terminally completed session auto-dismisses
- **WHEN** a backgrounded session's task reaches terminal completion
- **THEN** its row is auto-dismissed forever on the next pass regardless of age

#### Scenario: A completion under the reader's eyes does not vanish
- **WHEN** a session's task reaches terminal completion while that session is expanded
- **THEN** the session stays open showing the result, its row becomes idle, and it later expires by the auto-dismiss countdown like any idle session

#### Scenario: Discard cancels pending work but does not undo completed side effects
- **WHEN** the user deletes a session that has pending generation and an already-completed side effect
- **THEN** the pending generation is cancelled (not marked failed) and the session is removed, while the completed side effect remains and is not rolled back

## REMOVED Requirements

### Requirement: Overscroll-park flies the canvas into the notch home zone
**Reason**: Conversations no longer exist on the launcher canvas — the AI command band is one-shot-only (see `ai-command-band`), so there is nothing to park from it; sessions are born at the notch instead.
**Migration**: Create sessions from the rail's "+ New chat" card. The overscroll-park consumer seam, the canvas-at-bottom gate, and the park decision helper are deleted; the gesture recognizer was never modified and needs no change.

### Requirement: Pulling a card back restores it as the active conversation
**Reason**: Sessions never leave the notch — restoring onto the launcher canvas contradicted the notch-native model (a session stays at the notch until expiry or deletion).
**Migration**: Clicking a card **expands it in place** into the notch-anchored conversation panel (see "A card expands in place into a notch-anchored conversation panel"); badge/glow clearing on expansion is unchanged from the restore behavior.
