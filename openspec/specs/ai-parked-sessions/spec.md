# ai-parked-sessions Specification

## Purpose
Define the notch-native conversational sessions: the notch home zone (merged black-on-black with a physical notch, degrading to a top-center tab), the cursor-reveal rail of session cards with a persistent "+ New chat" card, sessions that are born at the notch (durable from their first message — an empty new chat is never saved), expand in place into a notch-anchored conversation panel (typed composer with a focused-only key flip, Approve/Skip buttons, Copy on answers), collapse back to background scheduling without cancelling an in-flight turn, per-card state badges (including a persistent needs-you badge), the one-active-now/K-ready scheduler seam, the durable store, and the expiry (auto-dismiss countdown) / deletion (authoritative discard) lifecycle. Sessions live only at the notch; the launcher's quick actions are one-shot and never appear here (see `ai-command-band`).
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
Each parked session SHALL carry an observable state — **thinking**, **done**, **needs-you**, or **failed** — and the rail card for that session SHALL render a badge reflecting it. The **done** badge SHALL show the count of unseen results. The **failed** badge SHALL carry only a clean, user-facing headline (from the single error translator); raw error text SHALL appear only behind an opt-in disclosure in the **expanded conversation panel**, never in the badge. A side effect that did not land SHALL surface as **failed**, never as a false "done." The state SHALL be driven by the scheduler's advance feedback and the routing loop's observable state. A session **collapsed while its turn is in flight** SHALL surface honestly on the rail: a detached **streaming** turn shows the **thinking** badge; a detached turn **paused at an approval** shows the **needs-you** badge.

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

### Requirement: Crossing behind the notch reveals an expanding rail of parked sessions
Crossing the cursor **up behind the notch** SHALL reveal a **rail** of parked-session cards, **always including the persistent "+ New chat" card**. The **"+ New chat" card SHALL lead** the rail; the session cards SHALL follow it ordered **most-recently-used first** (by last activity), so the last-used session sits immediately after the "+ New chat" card and older sessions trail toward the far end. The reveal trigger SHALL be the physical notch cutout itself — the rail reveals ONLY when the cursor crosses UP into the notch band (its usable "behind the notch" space, reachable because within the notch's horizontal span the cursor travels up to the physical top), **never** when it merely grazes the resting strip below the notch. On a **notchless/external** display, which has no notch to cross, the trigger SHALL be a **thin band hugging the physical top edge at top-center** (slamming the cursor to the very top edge), mimicking the same deliberate gesture. On a notched display the rail SHALL **emerge from the notch as a downward extension** — its top spanning up behind the notch (reaching the physical top), the cards spreading **downward** below the notch; on a notchless/external display the rail SHALL **hang below** the top-center tab. The rail SHALL be **non-scrollable**: the panel SHALL be sized to **hug every rendered card** (the persistent "+ New chat" card plus one per session) and SHALL **expand** as sessions are added rather than scrolling, up to a screen-fraction safety ceiling. On a notched display the panel SHALL be sized so the **centered** card row has **symmetric** vertical padding of the **notch height plus a small clearance** on top and bottom — so the cards clear the notch (never clipped at the head) and sit **balanced**, not shoved to the bottom. The reveal SHALL reuse the edge-gated cursor-reveal pattern (a passive global cursor monitor needing **no new permission**; geometry read only when the cursor is near the trigger/live region while hidden; a unified live area — the resting zone, the rail, **and the notch band** — with a grace-period dismiss, so once shown, moving the cursor **up into the notch OR back down onto the rail docks** rather than dismisses; a coarse re-feed while shown). The resting strip below the notch SHALL remain a keep-open bridge inside the live area (it just no longer triggers the reveal). The reveal SHALL be gated by a small, **user-configurable dwell**: the cursor SHALL remain crossed behind the notch (inside the trigger) **continuously** for the dwell before the rail reveals, so a quick pass THROUGH the notch (reaching for the menu bar or travelling to another corner) does not pop the dock; leaving the trigger before the dwell elapses SHALL cancel it (a re-entry restarts it), a dwell of **zero** SHALL reveal immediately, and the reveal timing SHALL not depend on continued cursor movement (a perfectly still cursor still reveals once the dwell elapses). The dwell SHALL apply to the hidden→shown transition ONLY (keep-open is instant). The grace-period dismiss SHALL apply **only while the panel is in rail mode** (an expanded conversation never grace-dismisses). The panel SHALL open and close by **growing from a point behind the notch to the full dock and shrinking back** — a fluid, spring-driven "droplet" spread anchored at its top edge, so the panel's **border itself stretches out of the point** (unfurling downward and out to both sides) and shrinks back into it. There SHALL be **no opacity fade** — the animation is geometric (the shape/border stretching), not a cross-fade. A **rail↔expanded** size change (opening a card / new chat into the conversation panel, or collapsing back) SHALL likewise **stretch the border between the two sizes** rather than snapping or fading. Teardown for the grace-dismiss MAY defer the order-out until the shrink completes, but restore and feature-off teardown SHALL remain **synchronous** (the ghost-on-Space-switch path).

#### Scenario: Crossing behind the notch reveals the rail
- **WHEN** the cursor crosses up behind the notch (into the notch band on a notched display), or slams to the physical top edge at top-center on a notchless/external display
- **THEN** the rail of parked-session cards — always including the "+ New chat" card — is revealed, emerging downward from the notch on a notched display, or hanging below the tab on a notchless/external display

#### Scenario: Grazing the strip below the notch does not reveal
- **WHEN** the cursor moves across the resting strip just below the notch (without crossing up into the notch band) while the rail is hidden
- **THEN** the rail is NOT revealed (only crossing behind the notch triggers it)

#### Scenario: A dwell gates the reveal
- **WHEN** a reveal dwell is configured and the cursor crosses behind the notch but leaves the trigger before the dwell elapses
- **THEN** the rail does not reveal; it reveals only once the cursor stays crossed behind the notch continuously for the dwell (a dwell of zero reveals immediately, and a still cursor still reveals)

#### Scenario: The panel grows from a point and shrinks back (no fade)
- **WHEN** the rail is revealed and later grace-dismissed
- **THEN** it grows from a point behind the notch to the full dock (its border stretching out of the point, no opacity fade) and shrinks back into the point on a fluid spring anchored at the top edge, and a reveal arriving mid-shrink cancels the teardown

#### Scenario: Opening or closing a conversation stretches the border between sizes
- **WHEN** a card is opened (or a new chat created) into the expanded conversation panel, or the conversation is collapsed back to the rail
- **THEN** the panel's border fluidly stretches between the rail size and the expanded size (rather than snapping or fading), the frame animation running to completion without a per-tick reposition snapping it

#### Scenario: The dock expands with each session rather than scrolling
- **WHEN** a new session is added to the dock
- **THEN** the panel widens to hug all cards (the "+ New chat" card plus one per session) and the rail does not scroll (within the parked-session cap)

#### Scenario: Cards sit balanced and clear of the notch
- **WHEN** the rail is revealed on a notched display
- **THEN** the panel is sized so the centered card row has symmetric padding of the notch height plus a small clearance on top and bottom — the cards clear the notch (none clipped behind it) and sit balanced, not shoved to the bottom

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

### Requirement: Durable parked-session store survives relaunch with a one-line resume
The system SHALL durably persist each parked session's conversation (encodable) keyed by its session identity, plus the lightweight rail/scheduler rows, so that parked sessions and the rail rebuild after relaunch. The store SHALL be the **single** owner of parked-conversation persistence (it does not duplicate the conversation type, which the conversation-runtime capability owns). Because sessions are durable **from their first message** (see "Sessions are born at the notch from the new-chat card"), a relaunch SHALL rebuild every session that had sent at least one message and had not yet expired or been deleted — including one created moments before quit with a message sent but no completed turn. An **empty** new chat (opened but never messaged) SHALL NOT be persisted and SHALL leave nothing to rebuild. File and coding failures SHALL be mapped at the store boundary into the capability's error type and surfaced bounded and non-blocking — never a raw thrown error and never silently dropped.

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

### Requirement: Parked-session errors use one taxonomy and are bounded and non-blocking
All parked-session failures SHALL be classified into the shared error taxonomy — reusing the existing runtime/task errors, plus at most one capability-specific error type for store/persistence cases the shared taxonomy cannot carry — and SHALL be surfaced through the single error translator as a clean headline with opt-in copyable details. A failure SHALL be an observable failed state (a failed badge / a failed restore with Retry), **never** an app-modal alert (which would freeze the Settings window) and **never** raw error text in a headline.

#### Scenario: A failed restore is bounded and non-blocking
- **WHEN** restoring a parked session fails
- **THEN** the failure is shown as a bounded, non-blocking failed state with a clean headline and a Retry, and no app-modal alert appears

#### Scenario: Raw error text never reaches a headline
- **WHEN** any parked-session error is surfaced
- **THEN** the headline is the clean translated message and any raw text is available only behind an opt-in disclosure or in logs

### Requirement: Sessions are born at the notch from the new-chat card
The revealed rail SHALL always include a persistent **"+ New chat"** card — including when no sessions exist (an empty dock still reveals a purposeful surface). Activating it SHALL create a new conversational session (a fresh conversation with a stable session identity) and expand it in place for typing, but SHALL **NOT** persist it yet — an **empty** new chat is **never** written to the store and **never** shown as a rail card. The session SHALL become **durable on its first message**: sending the first turn writes the conversation to the durable store and registers it with the scheduler (so it survives relaunch from that moment and joins the dock, ordered most-recently-used). The message SHALL be saved even if the model is momentarily unavailable (the message is never dropped). If the new chat is **closed while still empty** (collapsed/closed without a message), it SHALL be **discarded** — no store row, no rail card, nothing to rebuild on relaunch. The notch SHALL be the **only** surface that creates conversational sessions: the launcher's AI command band never creates, parks, or transfers a session here (quick actions are one-shot and ephemeral — see `ai-command-band`). A session SHALL remain at the notch for its whole life — background-advancing, collapsing, and expanding in place — until it is removed by **expiry** (the auto-dismiss countdown) or **deletion** (discard); there SHALL be no operation that moves it to another surface.

#### Scenario: New chat is not saved until the first message
- **WHEN** the user activates the "+ New chat" card on the rail
- **THEN** the panel expands in place ready for the first typed turn, but nothing is written to the store and no rail card is created; only when the first message is sent is the session persisted, registered with the scheduler, and docked

#### Scenario: An empty new chat closed without a message is discarded
- **WHEN** the user opens a new chat and closes it (collapses/swipes it away) without sending a message
- **THEN** the session is discarded — it leaves no store row, no rail card, and nothing to rebuild on relaunch

#### Scenario: The new-chat card is present on an empty dock
- **WHEN** the rail is revealed while no sessions exist
- **THEN** the rail shows the "+ New chat" card, and no empty-state dead end is presented

#### Scenario: A session lives only at the notch
- **WHEN** a session exists in the notch dock
- **THEN** every interaction with it (expand, type, approve, collapse, delete) happens on the notch surface, and no affordance moves it onto the launcher canvas or any other surface

### Requirement: A card expands in place into a notch-anchored conversation panel
Clicking a session card (or creating a new chat) SHALL expand the notch panel **in place** into a conversation view for that session — the same merged-notch panel and chrome, mode-switched from the rail, never a second panel. The thread SHALL open scrolled to its **latest turn** — an existing session with history lands at the **end** of its conversation, not at the top — and SHALL stay pinned to the newest turn as it streams. The expanded view SHALL render the session's thread (user and assistant turns, with the assistant's reasoning behind a collapsible section and streaming shown live), the ordered tool steps the routing loop has run, and a typed **composer**: Enter sends the turn; the panel SHALL become the **key window only while the composer field is focused** so keystrokes reach it, SHALL never become the main window, SHALL never activate the app, and SHALL drop key status when the conversation collapses so the previously frontmost app keeps focus. When the session's routing loop pauses awaiting a decision, the expanded view SHALL present the review as a card with explicit **Approve** and **Skip** buttons (the notch is a cursor-and-keyboard surface; the launcher's two-finger compass grammar is not imported). Each assistant answer SHALL offer a **Copy** affordance (the notch surface writes nothing into other apps). Exactly **one** session SHALL be expanded (foreground) at a time; expanding another card SHALL first collapse the current one. **Collapse** — via an explicit collapse affordance, Escape from the composer, or clicking the notch resting zone — SHALL persist the conversation back to the store, return the panel to rail mode, and hand the session back to background scheduling **without cancelling an in-flight turn** (the turn completes in the background and updates the card's badge). **An in-flight turn INCLUDES one paused at an approval:** collapsing while the routing loop awaits an Approve/Skip decision SHALL keep the suspended step alive (the session surfaces as needs-you), and re-expanding SHALL re-present the same approval card whose Approve/Skip resumes the original paused step — the turn is never restarted or silently dropped by a dock/expand round-trip. While a conversation is expanded, cursor departure SHALL NOT dismiss the panel (the grace-dismiss applies to rail mode only); feature-off and Space-switch teardown SHALL remain synchronous.

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

### Requirement: The expanded conversation speaks the fast-vs-soft trackpad grammar
While a conversation is **expanded** at the notch, the system SHALL recognize **two-finger flick** gestures from the trackpad, discriminated from reading-scrolls by the canonical flick classification (a dominant-axis travel floor, a dominant-axis **peak velocity** at or above the flick velocity threshold, and a **lift** arriving within the flick lift-window of the last fast frame — the same classification, thresholds, and tunables as the launcher canvas resolve):

- A **fast flick UP** SHALL **minimize the conversation into the notch dock**: the session performs the standard collapse (the snapshot persists, background scheduling continues, and an in-flight turn is never cancelled), and the **panel closes straight** — it SHALL shrink from its expanded size **directly into the point behind the notch** in one motion, **without** first stretching to the rail size and then dismissing (no intermediate "dwell on the dock"). The closing panel SHALL show the **conversation itself** shrinking; it SHALL NOT flash the empty "new chat" state or the rail on the way out (the conversation stays bound through the shrink; the state-collapse happens once the panel is hidden). The session remains parked (its card returns on the next reveal). This differs from the explicit **collapse affordance / Escape**, which returns the panel to the **visible rail** (so another card can be opened).
- A **fast flick RIGHT** SHALL **purge-delete** the session (see the purge requirement below).
- **Fast DOWN and fast LEFT SHALL be reserved no-ops** (no action, no dismissal), so the grammar can grow without destructive defaults.
- A **soft swipe** in any direction (sub-threshold peak velocity, or a decelerated hold-then-lift outside the lift window) SHALL emit **no gesture** — two-finger scrolling of the thread remains fully native and untouched. Gesture recognition SHALL be **watch-only** (read passively from the multitouch feed), never consuming or altering the scroll events the panel receives.

The grammar SHALL apply **only while a conversation is expanded** (never in rail mode), and SHALL NOT capture wider gestures: a **three-or-more-finger** contact SHALL behave exactly as if no conversation were expanded (the window switcher and launcher remain fully usable while a chat is open). The launcher's own modal gesture states (the AI preview canvas, the Files drill) SHALL take precedence when active.

#### Scenario: A fast flick up minimizes the conversation to the dock
- **WHEN** a conversation is expanded and the user performs a fast two-finger flick up (travel floor crossed, peak velocity at or above the threshold, prompt lift)
- **THEN** the conversation collapses into its notch dock card via the standard collapse — persisted, still background-scheduled, an in-flight turn not cancelled — and the panel closes straight, shrinking from the expanded size directly into the point behind the notch (no rail-size intermediate), leaving the session parked for the next reveal

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
