## ADDED Requirements

### Requirement: AI command opens a conversational canvas showing the seed and waiting

When an AI command is triggered with copied content (input source `selection`, `clipboard`, `clipboardImage`, or `screenRegion`), the system SHALL open a **conversational canvas** that **shows the acquired seed** as the conversation's first user turn and **waits** — it SHALL NOT auto-fire the model for a conversational (empty-question) command. The acquired seed (text and/or image) SHALL populate **turn 1's** user message; the canvas SHALL idle in a **waiting state** (`.awaitingSeed`) until the user sends. Sending (Enter, or the commit-bound excursion while waiting) SHALL begin the model turn; the existing acquisition outcomes SHALL be preserved — an input-requiring command with no input SHALL surface the **no-input** state (no conversation opens, no model call), a `screenRegion` permission gap SHALL surface a **failed** state naming the permission, and an unavailable model SHALL surface the **unavailable** enable/download canvas — exactly as before, so the canvas never opens an empty thread on a missing seed.

A **preset** command (a quick action such as Fix Grammar, or a Translate command) SHALL be the SAME conversational canvas with turn 1 **pre-filled** (the command's canned instruction folded with the seed, with any `{lang}` resolved) and **auto-sent**, so it streams immediately as turn 1 of the thread — the one-shot preset behavior is preserved as a special case of the conversational machine, not a separate surface.

#### Scenario: A conversational command opens showing the seed and waits

- **WHEN** an "Ask…"-style AI command is fired on copied text
- **THEN** the canvas opens showing the copied text as turn 1 and waits for the user, and the model is not invoked yet

#### Scenario: A preset command auto-sends turn 1

- **WHEN** a Fix Grammar command is fired on selected text
- **THEN** the canvas opens with turn 1 pre-filled (the fix-grammar instruction folded with the selection) and auto-sends, streaming the result immediately

#### Scenario: A missing seed surfaces no-input, not an empty thread

- **WHEN** an input-requiring command is fired and neither selection nor clipboard yields text
- **THEN** the canvas shows the no-input state and no conversation is opened

### Requirement: The typing float-up and Enter-to-send composer

While the canvas is waiting on the seed, a placeholder ("Ask anything…") SHALL sit over the seed. The instant the user begins typing (or focuses the composer), the placeholder SHALL animate **up and off** the seed (a soft spring in the BubbleMorph spirit, with no new haptic), making room for the thread to grow. The composer SHALL be a focusable text field; pressing **Enter** SHALL **send** the composed turn. While a composer field is focused, the overlay panel SHALL become key so keystrokes reach the field, WITHOUT activating this app (the panel remains a non-activating panel, so the captured front app stays frontmost) and WITHOUT disabling the two-finger gesture resolution (recognized off the multitouch device, not window events), which SHALL keep working while the field is focused.

#### Scenario: The placeholder floats up on first keystroke

- **WHEN** the canvas is waiting on the seed and the user types the first character
- **THEN** the placeholder animates up off the seed and the typed text appears in the composer

#### Scenario: Enter sends the turn

- **WHEN** the user has typed a question and presses Enter
- **THEN** the question is appended as a user turn and the assistant turn begins streaming

#### Scenario: Typing keeps the captured app frontmost and gestures live

- **WHEN** the user focuses the composer and types
- **THEN** the captured front app remains frontmost and a fresh two-finger swipe still resolves the canvas

### Requirement: Multi-turn conversation in the canvas

After an assistant turn completes, the canvas SHALL idle awaiting the next user turn; typing again SHALL float the placeholder up again and Enter SHALL send the next turn. The system SHALL render the **running thread** of user and assistant turns, streaming the in-flight assistant turn incrementally. Each assistant turn SHALL render through the existing natural-base-direction text rendering, and its reasoning SHALL render through the existing **collapsible thinking section** (live for the in-flight turn, retained per-message for completed turns). A turn's reasoning (thinking) SHALL be shown but SHALL NEVER be re-fed as conversation history (the committed turn text is the history; thinking is display-only).

#### Scenario: A second turn continues the thread

- **WHEN** the first assistant turn has completed and the user types another question and presses Enter
- **THEN** the new user turn and the streaming assistant turn are appended below the prior turns in the same thread

#### Scenario: Thinking is shown but not re-fed

- **WHEN** an assistant turn streamed reasoning before its answer
- **THEN** the reasoning is shown in the collapsible thinking section and the next turn's context contains the answer text only, not the reasoning

### Requirement: Bare-seed default question per seed type

When the user sends a bare seed (the seed with no typed question — an empty composer at send time), the system SHALL supply a sane **default question chosen by the seed's type**: an **image** seed (`clipboardImage` / `screenRegion`) SHALL default to a describe / what-is-this question; a **text** seed (`selection` / `clipboard`) SHALL default to a summarize / explain question. The default SHALL be folded with the seed exactly as a preset instruction is, so a bare seed is always a valid turn 1 and the model is never invoked on an empty turn. A typed question SHALL replace the default.

#### Scenario: A bare image seed defaults to describe

- **WHEN** the user sends a copied image with no typed question
- **THEN** turn 1 asks the model to describe / identify the image and the result streams

#### Scenario: A bare text seed defaults to summarize

- **WHEN** the user sends copied text with no typed question
- **THEN** turn 1 asks the model to summarize / explain the text and the result streams

#### Scenario: A typed question replaces the default

- **WHEN** the user types a question before sending a seed
- **THEN** the typed question is turn 1 and no default question is used

### Requirement: The canvas affirm / scroll / discard / park gesture compass

The conversational canvas SHALL be resolved by the canonical two-finger compass at the consumer seam (the recognizer is unchanged, emitting raw axis-locked excursions past a threshold larger than incidental two-finger scrolling):

- **DOWN = affirm** — extract the **latest assistant turn** and route it per the command's output target (or, when a tool step is awaiting approval, approve that step). Affirm SHALL fire **only when the canvas is scrolled to the top**; a down excursion off the top SHALL be treated as scrolling the thread, not affirming.
- **UP = scroll**, and **overscroll-past-bottom = PARK**: a normal up excursion scrolls the thread; only when the thread is already at its bottom and the up excursion continues past an overscroll threshold (above incidental scroll) SHALL the canvas **park** the session (handing the live conversation to the parked-sessions home zone) and dismiss.
- **RIGHT = discard** — cancel any in-flight generation, write nothing, and dismiss.
- **LEFT = reserved** — a no-op for now.
- **Enter (keyboard) = send** the composed turn.

The scroll/affirm verb collision SHALL be resolved by these gates: affirm fires only at the top, and park fires only as an overscroll past the bottom, so the same up/down axis can scroll the thread without ever accidentally affirming or parking mid-scroll. Tool-step approval SHALL reuse the same compass: DOWN approves the pending step, RIGHT skips it.

#### Scenario: Down at the top affirms the latest answer

- **WHEN** the thread is scrolled to the top and the user performs a two-finger down swipe on a completed assistant turn
- **THEN** the latest assistant turn is routed to the command's output target and the canvas dismisses

#### Scenario: Down off the top scrolls, not affirms

- **WHEN** the thread is scrolled away from the top and the user performs a two-finger down swipe
- **THEN** the thread scrolls and nothing is affirmed

#### Scenario: Overscroll-past-bottom parks the session

- **WHEN** the thread is already at its bottom and the user continues a two-finger up excursion past the overscroll threshold
- **THEN** the session is parked to the notch home zone and the canvas dismisses without cancelling the conversation

#### Scenario: Up scrolls without parking when not at the bottom

- **WHEN** the thread is not at its bottom and the user performs a two-finger up swipe
- **THEN** the thread scrolls and the session is not parked

#### Scenario: Right discards the conversation

- **WHEN** the user performs a two-finger horizontal (right) swipe
- **THEN** any in-flight generation is cancelled, nothing is written, and the canvas dismisses

#### Scenario: Down approves an awaiting tool step

- **WHEN** a tool step is awaiting approval and the user performs a two-finger down swipe
- **THEN** the step is approved and executed; a right swipe instead skips it

### Requirement: One source per conversation; follow-up turns are pure text

A conversation SHALL have exactly **one** acquired source — the seed, which is turn 1. Every follow-up turn SHALL be **pure typed text**: sending a follow-up SHALL NOT re-acquire a selection, clipboard, or screen region, nor attach a new image. An explicit attach-a-new-seed affordance is a documented **future** capability and SHALL NOT be introduced silently in this behavior; no path SHALL add a second source to an open conversation.

#### Scenario: A follow-up turn carries no new source

- **WHEN** the user sends a follow-up turn after a vision (image) seed
- **THEN** the follow-up user turn contains only the typed text and no new image, and the original seed remains the conversation's only source

## MODIFIED Requirements

### Requirement: In-place output routing

For non-task output targets, after the **latest assistant turn** is affirmed (the conversational generalization of the prior commit) the system SHALL route it: `replaceSelection` replaces the front app's selected text (via selection replace when settable, else paste), `pasteAtCursor` pastes the result at the insertion point, and `previewOnly` shows the result without writing into the app. The output SHALL be delivered into the app that was frontmost when the launcher opened, and a write that did not land SHALL surface a **failed** state (never a false "Done"). The output target SHALL govern **only what the affirm (DOWN) does at the resolve seam** — which target the latest assistant turn extracts into, or that DOWN approves a pending tool step — and SHALL NOT change the shape of the conversation (the number of turns, the float-up, or the rendering are identical for every output target).

#### Scenario: Replace selection commits in place

- **WHEN** a `replaceSelection` command's latest assistant turn is affirmed
- **THEN** the front app's selection is replaced by the answer, in the app that was frontmost at open

#### Scenario: Preview-only never writes

- **WHEN** a `previewOnly` command's latest assistant turn is affirmed
- **THEN** the answer is shown but nothing is written into the front app, and the canvas dismisses

#### Scenario: Output target does not change the conversation shape

- **WHEN** a `replaceSelection` command and a `previewOnly` command are each run as multi-turn conversations
- **THEN** both render the same thread, float-up, and turns, differing only in what affirming the latest answer does
