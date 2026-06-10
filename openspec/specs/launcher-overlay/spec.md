# launcher-overlay Specification

## Purpose

Define the four-finger launcher overlay: activation on the home cell, item/context stepping, deterministic home-cell entry, dwell-to-arm with haptic and charge-ring feedback, lift-fires-only-when-armed semantics, and the context-band visual encoding.
## Requirements
### Requirement: Four-finger launcher activation
When the launcher opt-in is effective, a four-finger gesture whose horizontal travel crosses the four-finger activation threshold SHALL show the launcher overlay and place the selection on the deterministic home cell (the home band, home column). The overlay SHALL be a non-activating panel that never becomes key or steals focus, visible across all Spaces, consistent with the window switcher's overlay.

#### Scenario: Horizontal four-finger swipe opens the launcher
- **WHEN** the opt-in is effective and four fingers scrub horizontally past the activation threshold
- **THEN** the launcher overlay appears with the selection on the home cell

#### Scenario: Below threshold shows nothing
- **WHEN** four fingers move horizontally but never cross the activation threshold, then lift
- **THEN** no overlay is shown and nothing is fired

#### Scenario: Overlay does not steal focus
- **WHEN** the launcher overlay is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

### Requirement: Item stepping and context stepping
While the launcher overlay is active, horizontal travel SHALL step the selection between items within the current context band (one item per item-step distance, with carry), and vertical travel SHALL step the selection between context bands (one band per context-step distance, with carry). Stepping past the first/last item or band SHALL clamp (not wrap) unless wrap is configured.

The **Clipboard band** is an exception to the horizontal mapping above. Because it is a single-column master-detail list (key list + value preview), horizontal travel does NOT step items there; it is repurposed (RIGHT pins the selected entry, LEFT switches to the previous band — see the Clipboard band navigation requirement), while vertical travel scrubs between entries (rows) and, at the top edge, rises to the band headers exactly as elsewhere.

#### Scenario: Horizontal steps items
- **WHEN** the overlay is active on a normal band and the fingers move horizontally past the item-step distance
- **THEN** the selection moves to the adjacent item in the current band (and again per further item-step distance)

#### Scenario: Vertical steps context bands
- **WHEN** the overlay is active and the fingers move vertically past the context-step distance
- **THEN** the selection moves to the adjacent context band

#### Scenario: Selecting an empty edge clamps
- **WHEN** the selection is on the first item and the user steps backward
- **THEN** the selection stays on the first item (no wrap, by default)

#### Scenario: Clipboard band overrides horizontal stepping
- **WHEN** the overlay is active on the Clipboard band and the fingers move horizontally
- **THEN** the selection does not step to another entry; instead the pin / previous-band behavior applies

### Requirement: Deterministic home-cell entry
The launcher SHALL always enter on the same home cell, independent of which item or band was used last. The selection order SHALL be the fixed user-defined order and SHALL NOT be reordered by recency or frequency.

#### Scenario: Entry is positionally stable
- **WHEN** the user fires an item, then later re-opens the launcher
- **THEN** the selection starts on the same home cell as before (not on the last-fired item)

### Requirement: Dwell-to-arm with feedback
Landing the selection on an item and holding it (no further stepping) for at least the configured dwell duration SHALL arm that item. Arming SHALL be signalled by a haptic tick (best-effort) and a visual charge-ring that fills over the dwell duration and locks when armed. Moving the selection to another item SHALL reset the dwell and disarm.

#### Scenario: Dwell arms the item
- **WHEN** the selection rests on an item for at least the dwell duration
- **THEN** the item becomes armed, a haptic tick fires (if available), and the charge-ring shows armed

#### Scenario: Charge-ring tracks partial dwell
- **WHEN** the selection has rested on an item for less than the dwell duration
- **THEN** the charge-ring is partially filled and the item is not armed

#### Scenario: Moving off disarms
- **WHEN** an item is armed and the user steps to another item
- **THEN** the previous item disarms, its ring empties, and the new item begins its own dwell

### Requirement: Lift fires only when armed
Lifting the fingers SHALL fire the currently armed item; if no item is armed, lifting SHALL dismiss the overlay without firing anything. A quick scrub-and-lift (no dwell) SHALL therefore never fire an item. The overlay SHALL be ordered out **before** the armed item is fired, so an action that switches Spaces (e.g. Next/Previous Space) does not carry the still-visible overlay onto the destination Space (the panel can join all Spaces, so firing first would leave it lingering there).

An **AI command item** is an exception to the order-out-before-fire rule: firing it does NOT dismiss the overlay. Instead, firing **begins the command and opens its streaming preview canvas**, leaving the overlay visible; the command then resolves through the AI command preview-and-commit behavior (a fresh four-finger **down** swipe commits, a fresh four-finger **horizontal** swipe discards) rather than completing on this first lift. Because the firing lift has already raised the fingers, the canvas is resolved by a *new* swipe, never by re-lifting; a stray lift while the canvas is open is a no-op. The order-out-before-fire rule continues to apply to items that complete on lift (launches, Space switches, paste-on-fire).

#### Scenario: Armed lift fires
- **WHEN** an item is armed and the fingers lift
- **THEN** that item is fired and the overlay hides

#### Scenario: Unarmed lift dismisses
- **WHEN** the fingers lift while no item is armed
- **THEN** the overlay hides and nothing is fired

#### Scenario: Regret path
- **WHEN** an item is armed and the user keeps swiping off it, then lifts
- **THEN** nothing is fired and the overlay hides

#### Scenario: Space-switch action does not drag the overlay along
- **WHEN** an armed Next/Previous Space item is fired on lift
- **THEN** the overlay is dismissed before the Space switch, and it does not appear on the destination Space

#### Scenario: Armed AI command lift opens the preview canvas
- **WHEN** an armed AI command item is lifted
- **THEN** the command begins, the overlay stays visible, and its streaming preview canvas appears instead of the overlay dismissing

### Requirement: Context-band visual encoding
The launcher SHALL render each item as an icon plus a short label tinted/accented by its context band color, SHALL visually distinguish item kinds (e.g. a badge for presets, a marker for scripts), and SHALL show a band indicator (reusing the switcher's row-indicator gutter) colored per band.

#### Scenario: Bands are color-coded
- **WHEN** the overlay shows multiple context bands
- **THEN** each band and its indicator dot are shown in that band's configured color

#### Scenario: Presets are distinguishable
- **WHEN** an item is a preset
- **THEN** it is rendered with a badge that distinguishes it from single-action items

### Requirement: Clipboard band master-detail layout and content preview

The Clipboard band SHALL render as a master-detail layout rather than the icon grid: a multi-line list of truncated **keys** on the left (one entry per line, with a type glyph and a pin indicator when pinned) and a single large **value preview** on the right that shows the **actual content** of the currently selected entry — a rendered image for image entries, a content preview of the file (not merely its icon) for file entries, the full text for text entries, and a color swatch for color entries. The overlay SHALL be sized large enough to show several keys and a sizeable value preview at once. The value preview SHALL NOT be a separately focusable/navigable pane (there is no horizontal crossing into it); content that overflows the preview region MAY be clipped in this layout.

#### Scenario: Selecting an entry previews its real content
- **WHEN** the selection rests on an image, file, text, or color entry
- **THEN** the value preview shows that entry's actual rendered content (image, file content preview, full text, or color swatch), not just a type icon

#### Scenario: Keys list shows many entries with pin markers
- **WHEN** the Clipboard band is shown
- **THEN** the left column lists multiple truncated keys, one per line, and pinned entries display a pin indicator

### Requirement: Pin and previous-band via horizontal travel in the Clipboard band

In the Clipboard band, with an entry selected, horizontal travel SHALL be interpreted as: **RIGHT toggles the pin** state of the selected entry, and **LEFT switches to the previous band** (dropping the selection into that band's grid). Pinning via RIGHT SHALL give immediate feedback (a pin indicator, best-effort haptic) and SHALL NOT move the selection within the current session (consistent with the deferred-reorder pin model).

A horizontal action SHALL require a **deliberate excursion** whose travel exceeds a configurable threshold (clearly larger than the fine item-step distance), and SHALL fire **at most once per excursion** — the action is latched until the horizontal travel returns toward centre — so a small movement cannot pin/unpin repeatedly and holding an offset does not rapid-toggle. Vertical scrubbing SHALL clear any partial horizontal travel so it never pins by accident. The excursion distance SHALL be tunable.

#### Scenario: A small horizontal movement does not pin
- **WHEN** an entry is selected and the fingers move sideways less than the pin-excursion threshold
- **THEN** nothing is pinned and the band does not change

#### Scenario: A deliberate right flick pins exactly once
- **WHEN** an entry is selected and the fingers make a deliberate rightward excursion past the threshold (and keep moving)
- **THEN** the entry's pin state toggles exactly once, a pin indicator shows, and the selection stays on that entry

#### Scenario: Returning to centre re-arms the action
- **WHEN** after a pin flick the fingers return toward centre and then make another deliberate right excursion
- **THEN** the pin toggles a second time (back to its original state)

#### Scenario: Deliberate left flick leaves to the previous band
- **WHEN** an entry is selected and the fingers make a deliberate leftward excursion past the threshold
- **THEN** the overlay switches to the previous band with the selection in that band's grid

#### Scenario: Vertical scrubbing does not pin
- **WHEN** the user scrubs vertically through the key list with minor horizontal jitter
- **THEN** no entry is pinned (the partial horizontal travel is cleared by the vertical step)

### Requirement: Edge-triggered auto-repeat for all launcher navigation

While the launcher is active, holding the controlling contact at a trackpad edge SHALL **auto-repeat** the corresponding navigation step, on **both axes**: the horizontal edges repeat horizontal stepping (moving the item cursor within the grid, or switching bands when the cursor is on the headers row), and the vertical edges repeat vertical stepping (moving between grid rows / the Clipboard list). Auto-repeat SHALL **accelerate** the longer an edge is held. It SHALL apply to every band's navigation, not only overflowing lists — a step that has nowhere to go SHALL simply clamp. In the **Clipboard band**, horizontal auto-repeat SHALL be suppressed (there horizontal is the deliberate pin / previous-band action), while vertical auto-repeat still applies. A clamped step (one that does not move the selection) SHALL NOT reset the dwell, so holding at an edge with nothing further to reach still lets the current item arm and fire. Detection SHALL use hysteresis (enter < exit) so jitter at the boundary does not flap. The edge zone, base rate, acceleration, and maximum rate SHALL be tunable.

#### Scenario: Holding at a vertical edge keeps stepping rows
- **WHEN** the user scrubs to the end of finger travel at the bottom (or top) trackpad edge
- **THEN** the selection keeps advancing down (or up) without lifting, accelerating the longer the edge is held

#### Scenario: Holding at a horizontal edge keeps stepping items or switching bands
- **WHEN** the cursor is in a grid (or on the headers row) and the contact is held at the right/left edge
- **THEN** the item cursor keeps moving (or the band keeps switching) in that direction, accelerating, until it clamps

#### Scenario: Clipboard band suppresses horizontal auto-repeat
- **WHEN** the Clipboard band is active and the contact is held at a horizontal edge
- **THEN** no pin / previous-band action auto-repeats (only vertical auto-repeat applies there)

#### Scenario: A clamped edge does not block arming
- **WHEN** the selection is already at the end in the held direction and the contact stays at that edge
- **THEN** the auto-repeat is a no-op that does not reset the dwell, so the current item can still arm and fire

#### Scenario: Leaving the edge stops auto-repeat
- **WHEN** the contact moves back off the edge or lifts
- **THEN** auto-repeat stops

### Requirement: AI availability is resolved in the preview canvas, not by hiding items
AI-command items SHALL always appear and be fireable in the launcher regardless of whether AI is enabled or the model is downloaded. When an AI-command item is fired while AI is **disabled** or the selected model is **not yet available** (not downloaded or not ready), the overlay SHALL open the AI preview canvas in an **unavailable** state — a non-error presentation showing a clear message (a clean, bounded string — either an error headline routed through the single AI error→message translator, or a clear non-error guidance string; never raw error text), an **Enable** affordance that turns the AI opt-in on, a **Download** action that begins fetching the model, and a **model picker** to choose the desired model. This canvas SHALL be **dismissable with the normal swipe-to-resolve gesture** (a horizontal discard), and any download it starts SHALL continue **in the background** after dismissal. The unavailable state SHALL NOT be surfaced via an app-modal alert and SHALL NOT block; it is bounded and non-blocking per the AI error-handling convention. When AI is enabled and the model becomes ready, firing an AI-command item SHALL proceed to normal streaming.

#### Scenario: Firing an AI item with AI off opens the enable/download canvas
- **WHEN** an AI-command item is fired while the AI opt-in is off
- **THEN** the preview canvas opens in the unavailable state offering Enable, Download, and a model picker, and nothing is generated yet

#### Scenario: Firing with the model not downloaded offers download
- **WHEN** an AI-command item is fired while AI is enabled but the model is not downloaded
- **THEN** the canvas shows the unavailable state with a Download action and a model picker

#### Scenario: Canvas is dismissable and the download continues in the background
- **WHEN** the user starts the model download from the unavailable canvas and then dismisses the canvas with a horizontal discard swipe
- **THEN** the canvas closes and the download continues in the background

#### Scenario: Once available, firing streams normally
- **WHEN** AI is enabled and the selected model is ready and an AI-command item is fired
- **THEN** the command begins and its result streams into the preview canvas as usual (no unavailable state)

### Requirement: AI command streaming preview canvas
When an AI command is fired, the overlay SHALL present a preview canvas (reusing the master-detail preview surface) into which the model's result is **streamed incrementally** as it is generated. The captured front app SHALL remain frontmost throughout (the overlay stays non-activating), and the canvas SHALL show a loading state while the model is loading or before the first tokens arrive.

#### Scenario: Result streams into the canvas
- **WHEN** an AI command is generating
- **THEN** the preview canvas fills with the result incrementally rather than only at completion

#### Scenario: Loading is shown before tokens
- **WHEN** the model is loading or has not yet produced output
- **THEN** the canvas shows a loading state rather than appearing blank or frozen

#### Scenario: Front app stays focused
- **WHEN** the preview canvas is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

### Requirement: Swipe-to-resolve (commit / discard) for AI commands
After an AI command's result is shown in the preview canvas, a fresh four-finger **down swipe SHALL commit** the result (routing it per the command's output target — paste/replace, or run the task; "bringing the result into the document") and a fresh four-finger **horizontal swipe (deliberate excursion) SHALL discard** it (cancelling any in-flight generation and writing nothing). Committing or discarding SHALL then dismiss the overlay. A down swipe before the result is committable (still loading or streaming) SHALL be ignored — the user waits — while a horizontal discard SHALL be honored at any time. An **up** swipe SHALL be ignored, so a stray upward motion never throws the result away. Because the firing lift has already raised the fingers, resolution is always a new swipe; a re-lift while the canvas is open commits nothing.

#### Scenario: Down swipe commits
- **WHEN** the result is committable and the user swipes down
- **THEN** the result is routed to the command's output target and the overlay hides

#### Scenario: Down swipe before ready is ignored
- **WHEN** the user swipes down while the model is still loading or streaming
- **THEN** nothing is committed and the canvas stays open until the result is ready

#### Scenario: Horizontal swipe discards and cancels
- **WHEN** the result is streaming or shown and the user swipes horizontally to discard
- **THEN** generation is cancelled, nothing is written, and the overlay hides

#### Scenario: Up swipe is ignored
- **WHEN** the user swipes up while the canvas is open
- **THEN** nothing is committed or discarded and the canvas stays open

### Requirement: Armed-confirmation state for side-effecting tasks (when enabled)
For an AI command whose output is a side-effecting task **with `confirmBeforeRun` enabled** (the default for side-effecting tasks), the preview canvas SHALL enter a distinct **armed-confirmation ("review the action") state** that displays the parsed action's concrete fields before it can be committed; the side effect SHALL fire only from this confirmed commit. When `confirmBeforeRun` is disabled for the command, the canvas SHALL NOT require this extra state and the task commits on the normal commit (down) swipe. A horizontal discard swipe SHALL always cancel with no side effect.

#### Scenario: Task shows the parsed action before firing (review enabled)
- **WHEN** a side-effecting task whose command has confirmation enabled has produced its parsed action
- **THEN** the canvas enters the armed-confirmation state showing the action's fields, and nothing is applied yet

#### Scenario: Confirm commit fires the side effect
- **WHEN** the user commits from the armed-confirmation state
- **THEN** the task executes its side effect and the overlay hides

#### Scenario: Review disabled commits without the extra state
- **WHEN** a side-effecting task whose command has confirmation disabled is committed
- **THEN** the task executes on the normal commit (down) swipe without a separate armed-confirmation state

#### Scenario: Discard cancels the side effect
- **WHEN** the user swipes horizontally to discard before the side effect fires
- **THEN** no side effect occurs and the overlay hides

