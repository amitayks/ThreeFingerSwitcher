# ai-parked-sessions Specification

## Purpose
Define the notch-native conversational sessions: the notch home zone (merged black-on-black with a physical notch, degrading to a top-center tab), the cursor-reveal rail of session cards with a persistent "+ New chat" card, sessions that are born at the notch (durable from birth), expand in place into a notch-anchored conversation panel (typed composer with a focused-only key flip, Approve/Skip buttons, Copy on answers), collapse back to background scheduling without cancelling an in-flight turn, per-card state badges (including a persistent needs-you badge), the one-active-now/K-ready scheduler seam, the durable store, and the expiry (auto-dismiss countdown) / deletion (authoritative discard) lifecycle. Sessions live only at the notch; the launcher's quick actions are one-shot and never appear here (see `ai-command-band`).
## Requirements
### Requirement: The notch home zone attaches to the notch and degrades gracefully
The system SHALL provide a **notch home zone** — an interactive, **non-activating** overlay panel anchored **top-center** — as the resting place for parked sessions. The panel SHALL reuse the mouse-interactive, non-activating popup species (the Dock-preview overlay pattern): it SHALL accept hover and click, SHALL NOT become the app's key/main window, SHALL NOT steal focus from the foreground app, and SHALL tear down **synchronously** (ordered out, no deferred close that could ghost on a Space switch). The zone SHALL anchor with notch awareness, and on a notched display it SHALL read as a **downward extension of the notch itself**, not a panel floating below it. On a display that **reports a physical notch**, the zone and its revealed panel SHALL **attach to the notch**: the panel SHALL be a **plain rounded rectangle** whose top edge reaches the **physical top** of the display (drawing over the menu-bar strip beneath it), **horizontally centered on the cutout** and at least as wide as it. The notch SHALL NOT be carved out of the panel — because the panel fill is **opaque black** and the notch is black, the panel's black simply spans up **behind** the notch and the two read as **one continuous shape** (no cutout, no seam). The parked content SHALL be **centered** within the panel (both axes) so it sits clear of the notch that overlaps the top-center; it SHALL NEVER be rendered behind the notch. On a **notchless built-in display or an external display** it SHALL degrade to a **top-center menu-bar tab** hanging **below** the menu bar at a fixed margin, with all other parked-session behavior identical. The home zone SHALL **never** hard-depend on a physical notch: the notch box (position, width, height) SHALL be **detected at runtime** from the display's safe-area inset and the menu-bar areas flanking the camera housing, and its absence SHALL cleanly select the tab path.

#### Scenario: Notched display attaches the zone as an extension of the notch
- **WHEN** the active display reports a physical notch (a non-zero top safe-area inset with resolvable flanking menu-bar areas)
- **THEN** the home zone attaches flush to the notch as a plain black rounded rectangle whose black spans up behind the (also black) notch so they read as one continuous shape (no carved cutout), and the parked content is centered in the panel, clear of the notch

#### Scenario: Notchless or external display degrades to a top-center tab
- **WHEN** the active display reports no notch (a built-in notchless display or an external monitor)
- **THEN** the home zone degrades to a top-center menu-bar tab hanging below the menu bar and all parked-session behavior is otherwise identical

#### Scenario: The panel never steals focus and tears down synchronously
- **WHEN** the home zone is shown and later dismissed
- **THEN** it never becomes the app's key/main window, the foreground app stays the focus target, and the panel is ordered out synchronously

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

### Requirement: The needs-you escalation surfaces a persistent, non-intrusive needs-you signal
When a parked session escalates to **needs-you** (a dangerous write or required approval surfaced from the background-autonomy capability), the system SHALL signal it **ambiently and non-intrusively** — a peripheral cue, **not** an intrusive interruption. It SHALL NOT be a modal alert, SHALL NOT play a sound, SHALL NOT bounce, and SHALL NOT steal focus (the panel stays non-activating and never becomes key while unexpanded). The needs-you state SHALL be tracked while at least one parked session is in needs-you and SHALL **persist** until the user **addresses** every needs-you session (expanding it and resolving its pending decision, or deleting it); merely revealing the rail SHALL NOT clear it. The per-session signal SHALL live on the card as a **needs-you badge** (with the per-session count), so an escalation is never silently missable yet never blocks work.

> Note: the earlier always-on **animated ambient glow** on the notch zone was **removed** — hosted in a retained `NSHostingView`, its perpetual `TimelineView` breather pinned the main thread while idle (see `docs/postmortem-idle-cpu-spin.md`). The needs-you state is retained (`NotchHomeZoneController.hasNeedsYou` + the per-card badge); if a dedicated ambient cue returns later it MUST be gated on real window visibility.

#### Scenario: A background escalation surfaces the needs-you signal
- **WHEN** a parked session escalates to needs-you
- **THEN** the session's card shows a persistent needs-you badge and no modal alert, sound, bounce, or focus-steal occurs

#### Scenario: The needs-you signal persists until the escalation is addressed
- **WHEN** the user reveals the rail but does not yet expand-and-resolve or delete the needs-you session
- **THEN** the needs-you signal persists, and it clears only once every needs-you session has been addressed

#### Scenario: The needs-you signal is absent when nothing needs the user
- **WHEN** no parked session is in needs-you
- **THEN** no needs-you signal is shown

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

### Requirement: One active generation now, with a K-ready scheduler seam for batching
The system SHALL schedule parked sessions through a pure scheduler seam that decides which session each generation slot serves. The seam SHALL expose a slot-count-parameterized request for runnable sessions, an advance-feedback callback, and an escalation callback. In this capability exactly **one** generation SHALL be active and the rest SHALL be queued; the scheduler's runnable-set request SHALL honor the caller's slot count so that a later **batched** runtime can fill **K** slots at once as a **drop-in** with **no change** to the seam. Runnable sessions SHALL exclude those blocked on the user (needs-you) and those whose scheduled next-run time has not arrived, and SHALL be ordered deterministically (oldest-waiting first). The scheduler SHALL be pure — time SHALL be an input — so its decisions are deterministically testable. The foreground active session SHALL always be served (the scheduler fills only the remaining slots).

#### Scenario: Exactly one parked session is advanced at a time in this capability
- **WHEN** several sessions are parked and runnable and one generation slot is requested
- **THEN** the scheduler returns exactly one session, the oldest-waiting runnable one, and the rest stay queued

#### Scenario: The seam serves K slots without changing
- **WHEN** a batched runtime requests up to K runnable sessions through the same seam
- **THEN** the scheduler returns up to K runnable sessions with no change to the seam's shape (batching is a drop-in)

#### Scenario: Sessions blocked on the user or scheduled later are not runnable
- **WHEN** a session is in needs-you or its next-run time has not yet arrived
- **THEN** the scheduler does not include it in the runnable set

#### Scenario: Scheduling decisions are deterministic
- **WHEN** the scheduler is asked for runnable sessions with a given timestamp
- **THEN** its result depends only on the parked set and that injected timestamp, so it is reproducible in tests

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

### Requirement: Parked-session errors use one taxonomy and are bounded and non-blocking
All parked-session failures SHALL be classified into the shared error taxonomy — reusing the existing runtime/task errors, plus at most one capability-specific error type for store/persistence cases the shared taxonomy cannot carry — and SHALL be surfaced through the single error translator as a clean headline with opt-in copyable details. A failure SHALL be an observable failed state (a failed badge / a failed restore with Retry), **never** an app-modal alert (which would freeze the Settings window) and **never** raw error text in a headline.

#### Scenario: A failed restore is bounded and non-blocking
- **WHEN** restoring a parked session fails
- **THEN** the failure is shown as a bounded, non-blocking failed state with a clean headline and a Retry, and no app-modal alert appears

#### Scenario: Raw error text never reaches a headline
- **WHEN** any parked-session error is surfaced
- **THEN** the headline is the clean translated message and any raw text is available only behind an opt-in disclosure or in logs

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

### Requirement: The expanded conversation speaks the fast-vs-soft trackpad grammar
While a conversation is **expanded** at the notch, the system SHALL recognize **two-finger flick** gestures from the trackpad, discriminated from reading-scrolls by the canonical flick classification (a dominant-axis travel floor, a dominant-axis **peak velocity** at or above the flick velocity threshold, and a **lift** arriving within the flick lift-window of the last fast frame — the same classification, thresholds, and tunables as the launcher canvas resolve):

- A **fast flick UP** SHALL **minimize the conversation into the notch dock**: the panel collapses back to its rail card via the standard collapse (the snapshot persists, background scheduling continues, and an in-flight turn is never cancelled).
- A **fast flick RIGHT** SHALL **purge-delete** the session (see the purge requirement below).
- **Fast DOWN and fast LEFT SHALL be reserved no-ops** (no action, no dismissal), so the grammar can grow without destructive defaults.
- A **soft swipe** in any direction (sub-threshold peak velocity, or a decelerated hold-then-lift outside the lift window) SHALL emit **no gesture** — two-finger scrolling of the thread remains fully native and untouched. Gesture recognition SHALL be **watch-only** (read passively from the multitouch feed), never consuming or altering the scroll events the panel receives.

The grammar SHALL apply **only while a conversation is expanded** (never in rail mode), and SHALL NOT capture wider gestures: a **three-or-more-finger** contact SHALL behave exactly as if no conversation were expanded (the window switcher and launcher remain fully usable while a chat is open). The launcher's own modal gesture states (the AI preview canvas, the Files drill) SHALL take precedence when active.

#### Scenario: A fast flick up minimizes the conversation to the dock
- **WHEN** a conversation is expanded and the user performs a fast two-finger flick up (travel floor crossed, peak velocity at or above the threshold, prompt lift)
- **THEN** the conversation collapses into its notch dock card via the standard collapse — persisted, still background-scheduled, an in-flight turn not cancelled

#### Scenario: A soft scroll never minimizes or deletes
- **WHEN** a conversation is expanded and the user scrolls the thread with a slow two-finger scrub, or pauses before lifting
- **THEN** no gesture fires and the thread scrolls natively, exactly as without the grammar

#### Scenario: The switcher still works while a chat is open
- **WHEN** a conversation is expanded and the user performs a three-finger switcher swipe or a four-finger launcher swipe
- **THEN** the switcher/launcher behave exactly as if no conversation were expanded (the flick grammar watches two-finger excursions only)

#### Scenario: Fast down and fast left are reserved
- **WHEN** a conversation is expanded and the user performs a fast two-finger flick down or left
- **THEN** nothing happens (no collapse, no delete, no dismissal)

### Requirement: The purge-delete gesture removes the session with no trace
A **fast two-finger flick RIGHT** on the expanded conversation SHALL delete the session **completely and without trace**: the pending generation is cancelled (a cancellation is not a failure), the durable conversation and rail row are removed through the authoritative discard path, the bound engine is dropped, **and every audit-log record attributed to that session is purged** — from the in-memory ring and from the durable audit file. The purge path itself SHALL NOT write any log line or record referencing the session. Completed side effects in the outside world (a written calendar event, a moved file) are NOT rolled back — purge erases the app's own records of the session, not the world. The purge SHALL be **user-initiated only** (this gesture); the plain delete affordances (the card's context menu, the expanded header's delete) SHALL keep the standard discard, which leaves the audit ledger intact.

#### Scenario: A fast flick right purges the session everywhere
- **WHEN** a conversation is expanded and the user performs a fast two-finger flick right
- **THEN** the panel dismisses, the pending generation is cancelled, the durable conversation and rail row are removed, and the session's audit records are gone from both the in-memory ring and the durable audit file — with no new log line about the session

#### Scenario: A purged session leaves nothing after relaunch
- **WHEN** a session is purge-deleted and the app relaunches
- **THEN** no card, no conversation, and no audit record attributed to that session can be found anywhere

#### Scenario: A plain delete keeps the ledger
- **WHEN** the user deletes a session via the card's context menu or the expanded header's delete affordance
- **THEN** the session's conversation and row are removed but its audit-log records remain in the ledger

