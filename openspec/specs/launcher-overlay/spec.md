# launcher-overlay Specification

## Purpose

Define the four-finger launcher overlay: activation on the home cell, item/context stepping, deterministic home-cell entry, dwell-to-arm with haptic and charge-ring feedback, lift-fires-only-when-armed semantics, and the context-band visual encoding.
## Requirements
### Requirement: Four-finger launcher activation
When the launcher opt-in is effective, a four-finger gesture whose horizontal travel crosses the four-finger activation threshold SHALL show the launcher overlay. When more than one band exists, the overlay SHALL place focus on the **band list at the home band's icon**, with no item armed; when exactly one band exists, the overlay SHALL place the selection on the deterministic home cell (the home column of the single band), armable immediately. The overlay SHALL be a non-activating panel that never becomes key or steals focus, visible across all Spaces, consistent with the window switcher's overlay.

#### Scenario: Horizontal four-finger swipe opens the launcher on the home band icon
- **WHEN** the opt-in is effective, more than one band exists, and four fingers scrub horizontally past the activation threshold
- **THEN** the launcher overlay appears with focus on the home band's icon and nothing armed

#### Scenario: Single-band launcher opens on the home cell
- **WHEN** the opt-in is effective, exactly one band exists, and four fingers scrub horizontally past the activation threshold
- **THEN** the launcher overlay appears with the selection on the home cell of that band (no band list shown)

#### Scenario: Below threshold shows nothing
- **WHEN** four fingers move horizontally but never cross the activation threshold, then lift
- **THEN** no overlay is shown and nothing is fired

#### Scenario: Overlay does not steal focus
- **WHEN** the launcher overlay is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

### Requirement: Vertical band list with a side content pane

The launcher SHALL render the context bands as a vertical list of band **icons on the left** (icons only — never the band names) and the active band's content (the icon grid, or the Clipboard master-detail) on the **right**, replacing the previous horizontal tab row above the grid. Each band's icon SHALL be **user-configurable** (the same icon picker as items), the **Clipboard** band SHALL use a dedicated preset icon, and a newly created band SHALL start with a default icon (not a default name). The icons SHALL sit at a **fixed small spacing**, vertically centered in the column (not spread to fill it). Only the **active** (highlighted) band's icon SHALL be drawn in that band's color; the other icons SHALL be colorless until they become active. When more than one band exists the band list SHALL be shown; when exactly one band exists the band list SHALL be omitted and only the content pane shown.

The **left band column** SHALL be a fixed-width icon strip. The launcher **window height** SHALL be driven **solely by the active band's item rows** — a two-row band is exactly two rows tall, a three-row band three — clamped to a minimum and maximum, where the maximum fits the full visible-row cap. Each item row SHALL reserve room for its **item title** so labels are not clipped, and a band of up to the visible-row cap SHALL fit **without internal scrolling**; only beyond that cap SHALL the content grid scroll, keeping the selected item visible.

#### Scenario: Multiple bands show the icon list on the left
- **WHEN** the launcher is shown with more than one band
- **THEN** a vertical list of band icons (not names) appears on the left and the active band's content fills the pane on the right

#### Scenario: A single band shows only the content
- **WHEN** the launcher is shown with exactly one band
- **THEN** no band list is rendered and only the content pane (the icon grid) is shown

#### Scenario: Only the active band's icon is colored
- **WHEN** the band list is shown
- **THEN** the icons sit at a fixed small spacing centered in the column, the active band's icon is drawn in its band color, and the rest are colorless until selected

#### Scenario: Up to the row cap fits without scrolling
- **WHEN** the active band has N item rows, N within the visible-row cap
- **THEN** the window is exactly N rows tall (each row reserving its item title) with no internal scroll, and switching to another band with the same row count does not change the window height

#### Scenario: Beyond the row cap the grid scrolls
- **WHEN** the active band has more item rows than the visible-row cap
- **THEN** the window height is clamped at the cap and the content grid scrolls (keeping the selected item visible)

### Requirement: Item stepping and context stepping
While the launcher overlay is active, navigation SHALL be a 2D cursor split across the band list (left) and the content grid (right). Steps SHALL be **produced positionally** (see gesture-recognition's *Anchored positional navigation interpretation*): inside the **padding box** the cursor **tracks the finger's position** in discrete steps (moving back steps it back), and once the offset leaves the box — or reaches the **edge-margin band** — it **auto-repeats** along the eased curve, not per fixed distance of accumulated travel. The per-axis cursor topology is:

- With the **band list focused**, **vertical** offset SHALL switch the active band (one band per vertical step — a *deliberate* step), and **horizontal** offset toward the content SHALL cross the focus into the grid, landing on the band's home/first item. Horizontal offset away from the content SHALL clamp (there is nothing to the left of the band list).
- With the **grid focused**, **horizontal** offset SHALL step the selection between items within the current row (one item per horizontal step); from the **first column**, a further step toward the band list SHALL cross the focus back to the band list. **Vertical** offset SHALL step between grid rows and SHALL clamp at the first and last row (it no longer rises to a separate header row — the bands are reached horizontally now).

Stepping past the first/last band or item SHALL clamp (not wrap) unless wrap is configured.

The **Clipboard band** is an exception to the grid's horizontal mapping. Its content is a single-column master-detail list (key list + value preview): horizontal offset toward the content crosses into the **key list**, vertical offset scrubs between entries (rows), and horizontal offset within the key list is repurposed for pin / return-to-band-list (see the Clipboard band navigation requirement) rather than stepping items.

#### Scenario: Vertical switches bands on the band list
- **WHEN** the band list is focused and the vertical offset crosses the outer threshold (or auto-repeats while held)
- **THEN** the active band changes to the adjacent band (and again per further step), the content pane updates to that band, and the active band's icon is highlighted

#### Scenario: Horizontal crosses from the band list into the grid
- **WHEN** the band list is focused and the horizontal offset toward the content crosses the outer threshold
- **THEN** the focus crosses into the grid, landing on the band's first/home item (now armable)

#### Scenario: Horizontal steps items within a row
- **WHEN** the grid is focused on a normal band and the horizontal offset steps (not at the first column moving outward)
- **THEN** the selection moves to the adjacent item in the current row (and again per further step)

#### Scenario: Horizontal from the first column returns to the band list
- **WHEN** the grid is focused with the selection in the first column and the horizontal offset steps toward the band list
- **THEN** the focus crosses back to the band list at the active band's icon

#### Scenario: Vertical steps grid rows and clamps at the edges
- **WHEN** the grid is focused and the vertical offset steps
- **THEN** the selection moves to the adjacent row, clamping at the first and last row (it does not rise onto the band list)

#### Scenario: Selecting an empty edge clamps
- **WHEN** the selection is on the first item and the user steps backward within the row
- **THEN** the selection stays on the first item (no wrap, by default)

#### Scenario: Clipboard band overrides horizontal item stepping
- **WHEN** the grid is focused on the Clipboard band and the horizontal offset steps within the key list
- **THEN** the selection does not step to another entry; instead the pin / return-to-band-list behavior applies

### Requirement: Deterministic home-cell entry
The launcher SHALL always enter at the same deterministic place, independent of which item or band was used last: the **home band's icon** (band list focused) when more than one band exists, or the **home cell** (home column) when a single band exists. The band order and item order SHALL be the fixed user-defined order and SHALL NOT be reordered by recency or frequency.

#### Scenario: Entry is positionally stable
- **WHEN** the user fires an item, then later re-opens the launcher
- **THEN** focus starts on the same home band icon (or, for a single band, the same home cell) as before — not on the last-used band or last-fired item

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
The launcher SHALL render the band strip as a **vertical list of band icons on the left** (icons only, never names), with the **active** band's icon drawn in its band color and the rest colorless. It SHALL render each item as an icon plus a short label tinted/accented by its context band color, and SHALL visually distinguish item kinds (e.g. a badge for presets, a marker for scripts). Each band's icon is user-configurable; the Clipboard band uses a dedicated preset icon.

#### Scenario: The active band's icon is colored in the vertical list
- **WHEN** the overlay shows multiple context bands
- **THEN** the bands appear as a vertical list of icons on the left and only the active band's icon is drawn in its band color

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

In the Clipboard band, with the key list focused and an entry selected, horizontal travel SHALL be interpreted as: **RIGHT toggles the pin** state of the selected entry, and **LEFT returns focus to the band list** (with the Clipboard band active, from which vertical travel reaches the previous band). Pinning via RIGHT SHALL give immediate feedback (a pin indicator, best-effort haptic) and SHALL NOT move the selection within the current session (consistent with the deferred-reorder pin model).

A horizontal pin action SHALL require a **deliberate excursion** whose travel exceeds a configurable threshold (clearly larger than the fine item-step distance), and SHALL fire **at most once per excursion** — the action is latched until the horizontal travel returns toward centre — so a small movement cannot pin/unpin repeatedly and holding an offset does not rapid-toggle. Vertical scrubbing SHALL clear any partial horizontal travel so it never pins by accident. The excursion distance SHALL be tunable.

#### Scenario: A small horizontal movement does not pin
- **WHEN** an entry is selected and the fingers move sideways less than the pin-excursion threshold
- **THEN** nothing is pinned and the focus does not change

#### Scenario: A deliberate right flick pins exactly once
- **WHEN** an entry is selected and the fingers make a deliberate rightward excursion past the threshold (and keep moving)
- **THEN** the entry's pin state toggles exactly once, a pin indicator shows, and the selection stays on that entry

#### Scenario: Returning to centre re-arms the action
- **WHEN** after a pin flick the fingers return toward centre and then make another deliberate right excursion
- **THEN** the pin toggles a second time (back to its original state)

#### Scenario: Left returns to the band list
- **WHEN** an entry is selected and the fingers move left toward the band list
- **THEN** focus crosses to the band list with the Clipboard band active (vertical travel from there reaches the previous band)

#### Scenario: Vertical scrubbing does not pin
- **WHEN** the user scrubs vertically through the key list with minor horizontal jitter
- **THEN** no entry is pinned (the partial horizontal travel is cleared by the vertical step)

### Requirement: Edge-triggered auto-repeat for all launcher navigation

While the launcher is active, **holding the offset beyond the padding box** (or in the edge-margin band — *not* keyed to a physical trackpad edge) SHALL **auto-repeat** the corresponding navigation step, on **both axes**: a held vertical offset repeats vertical stepping (switching bands when the band list is focused, or moving between grid rows / the Clipboard list when the grid is focused), and a held horizontal offset repeats horizontal stepping (moving the item cursor within the grid, or crossing between the band list and the grid).

Auto-repeat cadence SHALL follow a **smooth eased acceleration curve over dwell duration**: position-tracking already steps the cursor to the box edge, then the **first** auto-repeat fires after a short initial delay, and the interval SHALL **shorten along a curve** (never an abrupt slow→fast jump) toward a fast minimum floor the longer the offset is held. Returning the offset back into the box SHALL stop auto-repeat; a small move back past the **back-off** SHALL stop it and re-center onto the finger. The same eased curve SHALL apply to **both axes on every navigation surface** (launcher grid, Clipboard list, and the Files navigator's highlight axis).

Auto-repeat SHALL apply to every band's navigation, not only overflowing lists — a step that has nowhere to go SHALL simply clamp. In the **Clipboard band**, horizontal auto-repeat SHALL be suppressed (there horizontal is the deliberate pin / return-to-band-list action), while vertical auto-repeat still applies. In the **Files navigator**, horizontal auto-repeat SHALL be suppressed (there horizontal *drills* the directory tree — descend/ascend a level — which must be a deliberate, discrete step, never auto-fired), while vertical (highlight) auto-repeat still applies. A clamped step (one that does not move the selection) SHALL NOT reset the dwell, so holding with nothing further to reach still lets the current item arm and fire. The padding-box size, edge-margin band, position-step, initial repeat delay, repeat floor, acceleration curve, and back-off SHALL be tunable.

#### Scenario: Holding a vertical offset keeps switching bands or stepping rows
- **WHEN** the user holds the vertical offset beyond the outer threshold (top or bottom)
- **THEN** the active band keeps switching (band list focused) or the row selection keeps advancing (grid focused) without lifting, the interval shortening along the eased curve the longer it is held

#### Scenario: Holding a horizontal offset keeps stepping items
- **WHEN** the grid is focused and the horizontal offset is held beyond the outer threshold
- **THEN** the item cursor keeps moving in that direction, accelerating along the eased curve, until it clamps (or crosses to the band list)

#### Scenario: First repeat is delayed, then the curve accelerates smoothly
- **WHEN** an offset is held just beyond the outer threshold
- **THEN** the first step fires immediately, the second fires after the initial repeat delay, and subsequent intervals shorten gradually along the curve toward the floor (not jumping straight to the fastest rate)

#### Scenario: Clipboard and Files bands suppress horizontal auto-repeat
- **WHEN** the Clipboard or Files band is active and a horizontal offset is held beyond the outer threshold
- **THEN** no pin / return-to-band-list or descend/ascend action auto-repeats (only vertical auto-repeat applies there)

#### Scenario: A clamped held offset does not block arming
- **WHEN** the selection is already at the end in the held direction and the offset stays beyond the outer threshold
- **THEN** the auto-repeat is a no-op that does not reset the dwell, so the current item can still arm and fire

#### Scenario: Returning to center stops auto-repeat
- **WHEN** the offset returns inside the inner deadzone or the contact lifts
- **THEN** auto-repeat stops and the axis re-arms

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
When an AI command is fired, the overlay SHALL present a preview canvas (reusing the master-detail preview surface) into which the model's result is **streamed incrementally** as it is generated. The captured front app SHALL remain frontmost throughout (the overlay stays non-activating), and the canvas SHALL show a loading state while the model is loading or before the first tokens arrive. The canvas SHALL be the surface for **vision (screen-region) command results** as well — a vision command's text result streams into the same canvas exactly as a text command's does.

#### Scenario: Result streams into the canvas
- **WHEN** an AI command is generating
- **THEN** the preview canvas fills with the result incrementally rather than only at completion

#### Scenario: Loading is shown before tokens
- **WHEN** the model is loading or has not yet produced output
- **THEN** the canvas shows a loading state rather than appearing blank or frozen

#### Scenario: Front app stays focused
- **WHEN** the preview canvas is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

#### Scenario: A vision command result streams into the same canvas
- **WHEN** a screen-region (vision) command is fired and the model produces a grounded answer
- **THEN** that answer streams into the same preview canvas as any text command's result

### Requirement: Swipe-to-resolve (commit / discard) for AI commands
After an AI command's result is shown in the preview canvas, a fresh **two-finger down swipe SHALL commit** the result (routing it per the command's output target — paste/replace, or run the task; "bringing the result into the document") and a fresh **two-finger horizontal swipe (deliberate excursion) SHALL discard** it (cancelling any in-flight generation and writing nothing). Committing or discarding SHALL then dismiss the overlay. A down swipe before the result is committable (still loading or streaming) SHALL be ignored — the user waits — while a horizontal discard SHALL be honored at any time. An **up** swipe SHALL be ignored, so a stray upward motion never throws the result away. The resolution swipe SHALL be a **deliberate excursion past a threshold larger than incidental two-finger scrolling**, so reading/scrolling the canvas is not mistaken for a resolve; because the firing lift has already raised the fingers, resolution is always a new swipe, and a re-lift while the canvas is open commits nothing.

This aligns the platform grammar: **four fingers open/dismiss the platform, two fingers act within it** — so the canvas (which is summoned by a two-finger trigger) is also resolved by two fingers, replacing the previous four-finger resolution.

#### Scenario: Two-finger down swipe commits
- **WHEN** the result is committable and the user makes a deliberate two-finger down swipe
- **THEN** the result is routed to the command's output target and the overlay hides

#### Scenario: Down swipe before ready is ignored
- **WHEN** the user swipes down while the model is still loading or streaming
- **THEN** nothing is committed and the canvas stays open until the result is ready

#### Scenario: Two-finger horizontal swipe discards and cancels
- **WHEN** the result is streaming or shown and the user makes a deliberate two-finger horizontal swipe to discard
- **THEN** generation is cancelled, nothing is written, and the overlay hides

#### Scenario: Up swipe is ignored
- **WHEN** the user swipes up while the canvas is open
- **THEN** nothing is committed or discarded and the canvas stays open

#### Scenario: Scrolling the canvas is not mistaken for a resolve
- **WHEN** the user scrolls the canvas content with a small two-finger motion below the resolve excursion threshold
- **THEN** the canvas scrolls and neither commit nor discard is triggered

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

### Requirement: In-canvas runtime-parameter (language) selection re-runs the command
For an AI command that declares a runtime parameter (v1: a target language), the preview canvas SHALL present an **in-canvas control** (a language dropdown) reflecting the command's active value. Choosing a different value SHALL **re-run the command in place** — cancelling the in-flight generation (cancellation is not a failure) and starting a new generation with the re-resolved prompt (`{lang}` ⇒ the new value) streaming into the same canvas — **without reopening the launcher** or losing the captured front app. The newly chosen value SHALL be persisted (per command) so the next run defaults to it, and the control's initial selection SHALL reflect that persisted value. The dropdown SHALL offer a fixed list of languages (no free-form text entry, keyboardless).

#### Scenario: Picking a language re-translates in place
- **WHEN** a translate result is shown and the user picks a different language from the in-canvas dropdown
- **THEN** the current generation is cancelled and the command re-runs to the new language, streaming into the same canvas

#### Scenario: The dropdown opens on the remembered language
- **WHEN** the user previously translated to "Hebrew" with this command and fires it again
- **THEN** the canvas opens with the dropdown set to "Hebrew" and translates to Hebrew by default

#### Scenario: Re-run keeps the captured app and output target
- **WHEN** the command re-runs after a language change
- **THEN** the captured front app remains frontmost and a subsequent commit still routes to the command's output target

#### Scenario: A command with no runtime parameter shows no dropdown
- **WHEN** a command that declares no runtime parameter is fired
- **THEN** the canvas shows no language dropdown

### Requirement: Collapsible live Thinking section and scrollable, input-capturing canvas
When a **reasoning** command streams, the preview canvas SHALL present the model's **thinking** in a **collapsible** section that is **collapsed by default** — showing a live activity indicator (a pulse + elapsed time) so the user can see the model is actively working (not stuck or silently slow) without it sprawling across the screen — **expandable on tap** to watch the thinking stream live, and **scrollable** when long. The committed/inserted result SHALL remain the **response** only (thinking is never committed). The canvas's thinking and response panes SHALL be **scrollable**, and while the canvas is open it SHALL **capture 1–2-finger scroll** (routing it to the canvas content, not the front app) until the canvas is dismissed; the four-finger commit/discard swipe SHALL continue to resolve the canvas.

#### Scenario: Thinking shows collapsed by default, expandable
- **WHEN** a reasoning command is generating
- **THEN** the canvas shows a collapsed Thinking section with a live pulse + elapsed timer; tapping it expands a scrollable live view of the thinking, and tapping again collapses it

#### Scenario: Only the response is committed
- **WHEN** the user commits a reasoning command's result
- **THEN** only the response is inserted into the front app (or used by the task); the thinking is never committed

#### Scenario: Scroll routes to the open canvas
- **WHEN** the canvas is open and the user does a 1–2-finger scroll
- **THEN** the canvas content scrolls (through the thinking or the response) rather than the front app, until the canvas is dismissed; a four-finger swipe still commits/discards

### Requirement: Bidirectional (RTL/LTR) text rendering in the preview canvas
The preview canvas SHALL render text **bidirectionally**: each paragraph's **base direction SHALL be natural (first-strong)** — derived from its first strong directional character — so a right-to-left paragraph (e.g. Hebrew or Arabic) starts from the correct side and aligns correctly, while a left-to-right paragraph remains left-aligned. **Mixed** left-to-right and right-to-left runs within a paragraph SHALL resolve via the Unicode Bidi algorithm so combined text reads cleanly (e.g. a Latin word or URL inside a Hebrew sentence). This SHALL apply to the **streamed output**, the **input echo**, and the **task-review fields**. Because streaming may deliver the first strong character late, the base direction SHALL be **recomputed as content streams** rather than fixed at the first token.

#### Scenario: A right-to-left result starts from the correct side
- **WHEN** the streamed result is Hebrew text
- **THEN** it renders right-aligned with a right-to-left base direction and correct punctuation placement

#### Scenario: Mixed-direction text resolves cleanly
- **WHEN** a paragraph contains both Hebrew and an embedded Latin word or URL
- **THEN** the paragraph's base direction follows its first strong character and the embedded run is placed correctly by the Bidi algorithm

#### Scenario: Base direction updates as tokens stream
- **WHEN** the first strong directional character arrives after some neutral characters have already streamed
- **THEN** the canvas updates the paragraph's base direction to match rather than locking to the environment direction

#### Scenario: Left-to-right text is unaffected
- **WHEN** the streamed result is English text
- **THEN** it renders left-aligned with a left-to-right base direction as before

