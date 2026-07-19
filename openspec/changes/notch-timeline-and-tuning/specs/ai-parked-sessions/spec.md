# ai-parked-sessions — delta for notch-timeline-and-tuning

## ADDED Requirements

### Requirement: A settings affordance morphs the panel into an in-notch tuning zone for new conversations
The rail SHALL host a **settings (gear) affordance stacked above the persistent "+ New chat" card**. Activating it SHALL morph the **same** notch panel in place into a **settings zone** — mode-switched like the expanded conversation, never a second panel, the rail↔settings size change stretching the border. The zone SHALL host a single **thinking + context slider** over **ordered discrete stops** — from a no-thinking/base-context stop, through balanced and deep stops, to a maximum stop (thinking on, model-maximum context) — each stop labeled with its thinking state and effective context-token count. The selected stop SHALL persist across relaunches and SHALL apply to **each conversation created after the change, until changed again**: a newborn conversation SHALL snapshot the stop's (reasoning, context-token) values **at birth** and carry them for its whole life (persisted with the conversation, decode-safe), its turns running with that reasoning flag and its compaction running against that context budget clamped to the model maximum. Moving the slider SHALL NOT retune any existing conversation (including a parked one re-expanded later). A conversation stored **before** this capability (no born-with tuning) SHALL keep the pre-change behavior (the global reasoning default and the injected budget). The settings zone SHALL remain **mouse-only** on the non-activating panel (it SHALL never take key status), a back affordance SHALL return the panel to rail mode, the grace-period dismiss SHALL apply in settings mode as in rail mode (a later reveal reopens the rail), and feature-off/Space-switch teardown SHALL remain synchronous.

#### Scenario: The gear morphs the panel into the settings zone and back
- **WHEN** the user clicks the gear above the "+ New chat" card and later clicks the back affordance
- **THEN** the same panel stretches in place into the settings zone and back to the rail — no second panel, no key status taken at any point

#### Scenario: The slider applies to following new conversations only
- **WHEN** an existing session is parked, the user moves the slider to a different stop, and then creates a new chat
- **THEN** the new conversation is born with the new stop's reasoning and context-token values (persisted with it), and the existing session keeps the tuning it was born under

#### Scenario: The selection persists across relaunch
- **WHEN** the user selects a stop and the app relaunches
- **THEN** the settings zone reopens showing that stop, and a conversation created after the relaunch is born with its values

#### Scenario: A no-thinking stop suppresses reasoning for conversations born under it
- **WHEN** the slider sits on the no-thinking stop and a new chat runs a turn
- **THEN** the turn requests no reasoning and no thinking segments appear, while a conversation born under a thinking stop still streams thinking

#### Scenario: A born-with context budget drives compaction
- **WHEN** a conversation born at a deep or maximum stop grows past its born-with token budget
- **THEN** compaction runs against that conversation's own budget (clamped to the model maximum), not the default or another conversation's budget

#### Scenario: Settings mode grace-dismisses like the rail
- **WHEN** the settings zone is open and the cursor leaves the live area for longer than the grace period
- **THEN** the panel dismisses (ordered out synchronously at the end of the shrink, as in rail mode) and the next reveal opens the rail

## MODIFIED Requirements

### Requirement: A card expands in place into a notch-anchored conversation panel
Clicking a session card (or creating a new chat) SHALL expand the notch panel **in place** into a conversation view for that session — the same merged-notch panel and chrome, mode-switched from the rail, never a second panel. The thread SHALL open scrolled to its **latest turn** — an existing session with history lands at the **end** of its conversation, not at the top — and SHALL stay pinned to the newest turn as it streams. The expanded view SHALL render the session's thread as a **timeline**: each assistant turn SHALL be an ordered sequence of **thinking and answer segments in token-arrival order** (a segment boundary wherever the channel flips), with answer segments rendered as normal turn text and thinking segments rendered visually distinct (muted) and collapsible **per block**. A live turn SHALL stream **both channels token-by-token into the timeline in arrival order** — including a **routed (tool-running) turn's final answer, which SHALL stream live rather than appearing whole at settle** — the in-flight thinking block streaming expanded and collapsing to a compact expandable row once the turn settles. The segment timeline SHALL be **persisted display-only per assistant turn**, so a historical turn re-renders its interleaved timeline after collapse/expand or relaunch; a turn stored **before** this capability (no segment timeline) SHALL render its flat stored reasoning as a single leading collapsible thinking block followed by its answer text. Thinking SHALL remain **display-only and never re-fed to the model** (assembly reads answer text only). The expanded view SHALL also render the ordered tool steps the routing loop has run, and a typed **composer**: Enter sends the turn; the panel SHALL become the **key window only while the composer field is focused** so keystrokes reach it, SHALL never become the main window, SHALL never activate the app, and SHALL drop key status when the conversation collapses so the previously frontmost app keeps focus. When the session's routing loop pauses awaiting a decision, the expanded view SHALL present the review as a card with explicit **Approve** and **Skip** buttons (the notch is a cursor-and-keyboard surface; the launcher's two-finger compass grammar is not imported). Each assistant answer SHALL offer a **Copy** affordance (the notch surface writes nothing into other apps). Exactly **one** session SHALL be expanded (foreground) at a time; expanding another card SHALL first collapse the current one. **Collapse** — via an explicit collapse affordance, Escape from the composer, or clicking the notch resting zone — SHALL persist the conversation back to the store, return the panel to rail mode, and hand the session back to background scheduling **without cancelling an in-flight turn** (the turn completes in the background and updates the card's badge). **An in-flight turn INCLUDES one paused at an approval:** collapsing while the routing loop awaits an Approve/Skip decision SHALL keep the suspended step alive (the session surfaces as needs-you), and re-expanding SHALL re-present the same approval card whose Approve/Skip resumes the original paused step — the turn is never restarted or silently dropped by a dock/expand round-trip. While a conversation is expanded, cursor departure SHALL NOT dismiss the panel (the grace-dismiss applies to rail and settings modes only); feature-off and Space-switch teardown SHALL remain synchronous.

#### Scenario: Expanding a card shows its thread and composer in place
- **WHEN** the user clicks a parked session's card on the rail
- **THEN** the same notch panel expands in place into that session's conversation view — timeline thread, tool steps, and composer — with no second panel and no surface change

#### Scenario: The panel is key only while the composer is focused
- **WHEN** the user focuses the composer, types a turn, and later collapses the conversation
- **THEN** keystrokes reach the composer while it is focused (the panel is key), the panel never becomes main and never activates the app, and on collapse key status is dropped so the previously frontmost app keeps focus

#### Scenario: Enter sends and thinking and answer stream interleaved in arrival order
- **WHEN** the user types a message in the expanded composer and presses Enter on a conversation born with reasoning on
- **THEN** the turn is appended to the session's conversation and the assistant's thinking and answer stream live into the thread as interleaved timeline segments in exactly the order the channels produced them — the live thinking block expanded while it streams, collapsing to a compact row at settle

#### Scenario: A routed turn's answer streams live
- **WHEN** a turn runs through the routing loop (tool steps) and reaches its final answer
- **THEN** the answer streams token-by-token into the timeline after the thinking that preceded it — it does not appear whole at settle

#### Scenario: A historical turn re-renders its interleaved timeline
- **WHEN** a session with settled turns is re-expanded, or rebuilt from the durable store after a relaunch
- **THEN** each assistant turn renders its persisted thinking/answer segments in original arrival order, thinking blocks collapsed to compact expandable rows

#### Scenario: A pre-change turn renders its flat reasoning as one leading thinking block
- **WHEN** a stored assistant message has no segment timeline (persisted before this capability)
- **THEN** it renders its flat stored reasoning as a single leading collapsible thinking block followed by its answer text, and nothing is dropped

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
- **THEN** the panel stays open (the grace-dismiss applies only to rail and settings modes), and it closes only via an explicit collapse, feature-off, or synchronous teardown paths

### Requirement: Crossing behind the notch reveals an expanding rail of parked sessions
Crossing the cursor **up behind the notch** SHALL reveal a **rail** of parked-session cards, **always including the persistent "+ New chat" card**. The **"+ New chat" card SHALL lead** the rail — with the **settings (gear) affordance stacked above it** — and the session cards SHALL follow it ordered **most-recently-used first** (by last activity), so the last-used session sits immediately after the "+ New chat" card and older sessions trail toward the far end. The reveal trigger SHALL be the physical notch cutout itself — the rail reveals ONLY when the cursor crosses UP into the notch band (its usable "behind the notch" space, reachable because within the notch's horizontal span the cursor travels up to the physical top), **never** when it merely grazes the resting strip below the notch. On a **notchless/external** display, which has no notch to cross, the trigger SHALL be a **thin band hugging the physical top edge at top-center** (slamming the cursor to the very top edge), mimicking the same deliberate gesture. On a notched display the rail SHALL **emerge from the notch as a downward extension** — its top spanning up behind the notch (reaching the physical top), the cards spreading **downward** below the notch; on a notchless/external display the rail SHALL **hang below** the top-center tab. The rail SHALL be **non-scrollable**: the panel SHALL be sized to **hug every rendered card** (the persistent "+ New chat" card plus one per session) and SHALL **expand** as sessions are added rather than scrolling, up to a screen-fraction safety ceiling. On a notched display the panel SHALL be sized so the **centered** card row has **symmetric** vertical padding of the **notch height plus a small clearance** on top and bottom — so the cards clear the notch (never clipped at the head) and sit **balanced**, not shoved to the bottom. The reveal SHALL reuse the edge-gated cursor-reveal pattern (a passive global cursor monitor needing **no new permission**; geometry read only when the cursor is near the trigger/live region while hidden; a unified live area — the resting zone, the rail, **and the notch band** — with a grace-period dismiss, so once shown, moving the cursor **up into the notch OR back down onto the rail docks** rather than dismisses; a coarse re-feed while shown). The resting strip below the notch SHALL remain a keep-open bridge inside the live area (it just no longer triggers the reveal). The reveal SHALL be gated by a small, **user-configurable dwell**: the cursor SHALL remain crossed behind the notch (inside the trigger) **continuously** for the dwell before the rail reveals, so a quick pass THROUGH the notch (reaching for the menu bar or travelling to another corner) does not pop the dock; leaving the trigger before the dwell elapses SHALL cancel it (a re-entry restarts it), a dwell of **zero** SHALL reveal immediately, and the reveal timing SHALL not depend on continued cursor movement (a perfectly still cursor still reveals once the dwell elapses). The dwell SHALL apply to the hidden→shown transition ONLY (keep-open is instant). The grace-period dismiss SHALL apply **only while the panel is in rail or settings mode** (an expanded conversation never grace-dismisses). The panel SHALL open and close by **growing from a point behind the notch to the full dock and shrinking back** — a fluid, spring-driven "droplet" spread anchored at its top edge, so the panel's **border itself stretches out of the point** (unfurling downward and out to both sides) and shrinks back into it. There SHALL be **no opacity fade** — the animation is geometric (the shape/border stretching), not a cross-fade. A **rail↔expanded** size change (opening a card / new chat into the conversation panel, or collapsing back) — and likewise a **rail↔settings** one — SHALL stretch the border between the two sizes rather than snapping or fading. Teardown for the grace-dismiss MAY defer the order-out until the shrink completes, but restore and feature-off teardown SHALL remain **synchronous** (the ghost-on-Space-switch path).

#### Scenario: Crossing behind the notch reveals the rail
- **WHEN** the cursor crosses up behind the notch (into the notch band on a notched display), or slams to the physical top edge at top-center on a notchless/external display
- **THEN** the rail of parked-session cards — always including the "+ New chat" card with the gear affordance above it — is revealed, emerging downward from the notch on a notched display, or hanging below the tab on a notchless/external display

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
- **WHEN** a card is opened (or a new chat created) into the expanded conversation panel, the settings zone is opened or closed, or the conversation is collapsed back to the rail
- **THEN** the panel's border fluidly stretches between the two sizes (rather than snapping or fading), the frame animation running to completion without a per-tick reposition snapping it

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
