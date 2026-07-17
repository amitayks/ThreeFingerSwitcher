## ADDED Requirements

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
