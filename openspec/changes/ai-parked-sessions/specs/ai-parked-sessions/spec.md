## ADDED Requirements

### Requirement: Overscroll-park flies the canvas into the notch home zone
The system SHALL let the user **park** the active AI conversation by overscrolling past the bottom of the canvas: when the canvas is already scrolled to its bottom and the user continues a two-finger **up** excursion past an **overscroll threshold** that sits **above** the incidental two-finger scroll threshold (`canvasResolveThreshold`), the canvas SHALL fly **up** and shrink into the notch home zone as a parked session. The park decision SHALL be interpreted at the consumer seam from the recognizer's raw direction — the gesture recognizer SHALL NOT be modified — mirroring the existing at-top commit guard (top of canvas = act, bottom = stash). A normal scroll that merely reaches the bottom SHALL NOT park; only the explicit past-bottom excursion above the threshold parks. The fly-up SHALL reuse the app's first-spring morph (the bubble morph) playing its recede side, so the canvas reads as receding toward the notch rather than vanishing.

#### Scenario: Overscroll past the bottom parks the conversation
- **WHEN** the canvas is scrolled to its bottom and the user continues a two-finger up excursion past the overscroll threshold
- **THEN** the canvas flies up and shrinks into the notch home zone as a parked session, keeping the conversation's identity

#### Scenario: A normal scroll to the bottom does not park
- **WHEN** the user scrolls the canvas to its bottom without exceeding the overscroll threshold
- **THEN** the canvas stays open and is not parked

#### Scenario: The recognizer is unchanged
- **WHEN** the park trigger is added
- **THEN** the gesture recognizer still emits only its raw direction and the park interpretation lives entirely at the consumer seam

### Requirement: The notch home zone degrades gracefully and never depends on a physical notch
The system SHALL provide a **notch home zone** — an interactive, **non-activating** overlay panel anchored **top-center** — as the resting place for parked sessions. The panel SHALL reuse the mouse-interactive, non-activating popup species (the Dock-preview overlay pattern): it SHALL accept hover and click, SHALL NOT become the app's key/main window, SHALL NOT steal focus from the foreground app, and SHALL tear down **synchronously** (ordered out, no deferred close that could ghost on a Space switch). The zone SHALL anchor with notch awareness: on a display that reports a notch it SHALL tuck just below the notch/menu bar; on a notchless built-in display or an **external display** it SHALL degrade to a **top-center menu-bar tab** at a fixed margin. The home zone SHALL **never** hard-depend on a physical notch.

#### Scenario: Notched display tucks the zone under the notch
- **WHEN** the active display reports a notch (a non-zero top safe-area inset)
- **THEN** the home zone anchors just below the notch, top-center

#### Scenario: Notchless or external display degrades to a top-center tab
- **WHEN** the active display reports no notch (a built-in notchless display or an external monitor)
- **THEN** the home zone degrades to a top-center menu-bar tab and all parked-session behavior is otherwise identical

#### Scenario: The panel never steals focus and tears down synchronously
- **WHEN** the home zone is shown and later dismissed
- **THEN** it never becomes the app's key/main window, the foreground app stays the focus target, and the panel is ordered out synchronously

### Requirement: Per-card state badges reflect each parked session's state
Each parked session SHALL carry an observable state — **thinking**, **done**, **needs-you**, or **failed** — and the rail card for that session SHALL render a badge reflecting it. The **done** badge SHALL show the count of unseen results. The **failed** badge SHALL carry only a clean, user-facing headline (from the single error translator); raw error text SHALL appear only behind an opt-in disclosure on the restored canvas, never in the badge. A side effect that did not land SHALL surface as **failed**, never as a false "done." The state SHALL be driven by the scheduler's advance feedback and the routing loop's observable state.

#### Scenario: A generating session shows the thinking badge
- **WHEN** a parked session is being advanced in the background
- **THEN** its card shows the thinking badge

#### Scenario: A completed session shows an unseen-result count
- **WHEN** a parked session produces a new result the user has not seen
- **THEN** its card shows a done badge with the unseen-result count

#### Scenario: A failed step shows a clean headline, never raw text
- **WHEN** a parked session's step fails
- **THEN** its card shows a failed badge carrying a clean headline only, and any raw detail is hidden behind an opt-in disclosure on the restored canvas

### Requirement: The needs-you escalation raises an ambient, peripheral notch glow
When a parked session escalates to **needs-you** (a dangerous write or required approval surfaced from the background-autonomy capability), the system SHALL signal it **ambiently** with a soft, slow **glow** on the notch home zone — a peripheral cue, **not** an intrusive interruption. The glow SHALL NOT be a modal alert, SHALL NOT play a sound, SHALL NOT bounce, and SHALL NOT steal focus (the panel stays non-activating and never becomes key). The glow SHALL appear **only** while at least one parked session is in needs-you and SHALL **persist** until the user **addresses** every needs-you session (restoring or dismissing it); merely revealing the rail SHALL NOT clear it. The per-session **count** SHALL live on the card; the zone glow SHALL be a binary present/slow-pulse signal, so an escalation is never silently missable yet never blocks work.

#### Scenario: A background escalation lights the ambient glow
- **WHEN** a parked session escalates to needs-you
- **THEN** the notch home zone shows a soft, slow ambient glow and no modal alert, sound, bounce, or focus-steal occurs

#### Scenario: The glow persists until the escalation is addressed
- **WHEN** the user reveals the rail but does not yet restore or dismiss the needs-you session
- **THEN** the ambient glow persists, and it clears only once every needs-you session has been addressed

#### Scenario: The glow is absent when nothing needs the user
- **WHEN** no parked session is in needs-you
- **THEN** the notch home zone shows no glow

### Requirement: Cursor-to-notch reveals a scrollable rail of parked sessions
Moving the cursor to the notch home zone SHALL reveal a **rail** of parked-session cards hanging below the zone. The rail SHALL be **horizontally scrollable** when it overflows. The reveal SHALL reuse the edge-gated cursor-reveal pattern (a passive global cursor monitor needing **no new permission**; geometry read only when the cursor is near the zone while hidden; a unified zone+rail live area with a grace-period dismiss; a coarse re-feed while shown). Teardown SHALL be **synchronous**. The cards SHALL bud in with the app's first-spring morph.

#### Scenario: Cursor near the notch reveals the rail
- **WHEN** the cursor moves to the notch home zone
- **THEN** the rail of parked-session cards is revealed below the zone

#### Scenario: The rail scrolls when it overflows
- **WHEN** there are more parked sessions than fit across the rail
- **THEN** the rail scrolls horizontally to reach the rest

#### Scenario: Leaving the zone and rail dismisses after a grace period
- **WHEN** the cursor leaves both the zone and the rail for longer than the grace period
- **THEN** the rail dismisses, ordered out synchronously

#### Scenario: The reveal needs no new permission
- **WHEN** the cursor-reveal monitor is installed
- **THEN** it observes cursor moves passively and requires no Input Monitoring or other new permission

### Requirement: Pulling a card back restores it as the active conversation
Pulling a parked card back (clicking it, or dragging it down past a small threshold) SHALL **restore** that session as the active AI canvas, re-seeded from its durable conversation. The restored session SHALL keep the **same session identity** so every subsystem still refers to the same session; its state SHALL become **active**; its unseen-result count SHALL clear; and if it was the last needs-you session, the ambient glow SHALL clear.

#### Scenario: Pulling a card back makes it the active canvas
- **WHEN** the user pulls a parked card back from the rail
- **THEN** that session becomes the active canvas, re-seeded from its stored conversation, keeping its session identity

#### Scenario: Restoring clears its badge and any glow it caused
- **WHEN** a parked session is restored
- **THEN** its unseen-result count clears and, if it was the last needs-you session, the ambient glow clears

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
The system SHALL durably persist each parked session's conversation (encodable) keyed by its session identity, plus the lightweight rail/scheduler rows, so that parked sessions and the rail rebuild after relaunch. The store SHALL be the **single** owner of parked-conversation persistence (it does not duplicate the conversation type, which the conversation-runtime capability owns). A sleeping session SHALL retain a **one-line resume** so a later restore re-primes cheaply. File and coding failures SHALL be mapped at the store boundary into the capability's error type and surfaced bounded and non-blocking — never a raw thrown error and never silently dropped.

#### Scenario: Parked sessions rebuild after relaunch
- **WHEN** the app relaunches with sessions previously parked
- **THEN** the rail rebuilds from the durable store, each card showing its title and state

#### Scenario: A store failure is observable, not silent
- **WHEN** persisting or reading a parked session fails
- **THEN** the failure is mapped into the capability's error type and surfaced as a bounded, non-blocking failed indicator, never a raw error and never silence

### Requirement: Lifecycle — max parked count, idle-timeout sleep, and discard semantics
The system SHALL bound and age parked sessions:
- A configurable **maximum parked count** SHALL be enforced by evicting the **least-recently-updated idle** session when the count is exceeded; an **active**, **needs-you**, or actively-**thinking** session SHALL NEVER be evicted.
- A session that stays **idle** longer than a configurable **idle timeout** SHALL **summarize-and-sleep**: its key/value cache SHALL be dropped to free memory (performed by the runtime capability through a seam), and a **one-line resume** SHALL be persisted so a later restore re-primes cheaply.
- **Discarding** a parked session SHALL cancel its pending generation via task cancellation (a cancellation is **not** a failure and SHALL NOT leave a failed badge) and remove its durable conversation. **Completed side effects SHALL NOT be rolled back** — work the session already committed (a written event, a moved file, a launched process) stays done; discard stops only future work.

#### Scenario: Exceeding the max evicts an idle session, never an active one
- **WHEN** the parked count exceeds the maximum and at least one idle session exists
- **THEN** the least-recently-updated idle session is evicted and no active, needs-you, or thinking session is evicted

#### Scenario: An idle session summarizes and sleeps
- **WHEN** a session stays idle past the idle timeout
- **THEN** its key/value cache is dropped and a one-line resume is persisted, so a later restore re-primes from that resume

#### Scenario: Discard cancels pending work but does not undo completed side effects
- **WHEN** the user discards a parked session that has pending generation and an already-completed side effect
- **THEN** the pending generation is cancelled (not marked failed) and the session is removed, while the completed side effect remains and is not rolled back

### Requirement: Parked-session errors use one taxonomy and are bounded and non-blocking
All parked-session failures SHALL be classified into the shared error taxonomy — reusing the existing runtime/task errors, plus at most one capability-specific error type for store/persistence cases the shared taxonomy cannot carry — and SHALL be surfaced through the single error translator as a clean headline with opt-in copyable details. A failure SHALL be an observable failed state (a failed badge / a failed restore with Retry), **never** an app-modal alert (which would freeze the Settings window) and **never** raw error text in a headline.

#### Scenario: A failed restore is bounded and non-blocking
- **WHEN** restoring a parked session fails
- **THEN** the failure is shown as a bounded, non-blocking failed state with a clean headline and a Retry, and no app-modal alert appears

#### Scenario: Raw error text never reaches a headline
- **WHEN** any parked-session error is surfaced
- **THEN** the headline is the clean translated message and any raw text is available only behind an opt-in disclosure or in logs
