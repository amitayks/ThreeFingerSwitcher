# switcher-overlay Specification

## Purpose

Define the non-activating overlay panel that renders the wrapped, real-proportion window grid and the live moving highlight, never steals focus, and appears above all content on the active screen.
## Requirements
### Requirement: Non-activating overlay that never steals focus
The overlay SHALL be a borderless, non-activating panel that ignores mouse events and does not become key or main, so the previously focused window can be raised cleanly on commit.

#### Scenario: Overlay does not take focus
- **WHEN** the overlay appears
- **THEN** the previously focused application remains the focus target for commit
- **AND** the overlay window is never itself a raise candidate

#### Scenario: Overlay ignores the pointer
- **WHEN** the overlay is visible and the pointer moves over it
- **THEN** mouse events pass through and do not interact with the overlay

### Requirement: Moving highlight tracks selection
The overlay SHALL visually highlight the currently selected card and SHALL update the highlight in real time as the selection index changes during scrubbing, across both horizontal (within-row) and vertical (between-row) movement.

#### Scenario: Highlight follows scrub
- **WHEN** the selection index changes during scrubbing
- **THEN** the highlight moves to the newly selected card without re-creating the grid

#### Scenario: Selected card kept visible
- **WHEN** the selected card would fall outside the visible area, horizontally or vertically
- **THEN** the canvas scrolls so the highlighted card remains visible

### Requirement: Overlay appears on the active screen above all content
The overlay SHALL appear on the active screen at a window level above normal windows and across all Spaces, and SHALL hide promptly on commit or cancel.

#### Scenario: Shown above other windows
- **WHEN** the overlay is activated
- **THEN** it renders above normal application windows on the active screen

#### Scenario: Hidden on end of gesture
- **WHEN** the gesture commits or cancels
- **THEN** the overlay hides promptly

### Requirement: Adaptive container width
The overlay container SHALL adapt to the solved grid: it SHALL present a large centered canvas (a fraction of the active screen's visible frame) into which the wrapped grid is laid out at the solved uniform scale, and the visible container SHALL hug BOTH its width and its height to the current Space's actual grid size, so a narrow Space yields a narrow centered container (not stretched to the full canvas width) and a partial last row leaves no empty space below. When the grid fits the canvas it SHALL NOT scroll; when the grid is taller than the canvas (many windows even at minimum scale) it SHALL clamp to the canvas height, stay centered, and scroll vertically to keep the highlighted card visible.

#### Scenario: Container hugs its content on both axes
- **WHEN** the overlay is shown for a Space whose wrapped grid is shorter and narrower than the canvas
- **THEN** the visible container's height equals the grid's actual height (no empty trailing rows) AND its width equals the grid's actual width (not stretched to the canvas width), and the container is centered on the active screen
- **AND** no scrolling occurs

#### Scenario: Overflowing grid clamps and scrolls vertically
- **WHEN** the overlay is shown for a Space whose grid is taller than the canvas even at minimum scale
- **THEN** the canvas height is clamped and centered
- **AND** scrubbing scrolls the grid vertically to keep the highlighted card visible

#### Scenario: Card metrics are a single source of truth
- **WHEN** the panel size is computed
- **THEN** it uses the same solved scale, wrapped rows, and card frames that the grid uses to lay out, so the two cannot diverge

### Requirement: Space-row display
The overlay SHALL group windows by Space, showing one Space's window grid at a time. Spaces SHALL be ordered by the true Mission Control (display) order, omitting Spaces with no switchable windows. This ordering SHALL be stable across reopens: a given Space occupies the same relative position regardless of which Space is currently active. The overlay SHALL open with the current Space's grid shown at its own position in that order (not moved to the first position). Vertical scrubbing SHALL switch to an adjacent Space ONLY when it would move past the top visual row (previous Space) or past the bottom visual row (next Space) of the current grid; between those edges, vertical scrubbing navigates the grid rows. The overlay SHALL show an indicator conveying which Space is shown and how many exist.

#### Scenario: Spaces follow Mission Control order
- **WHEN** the overlay is shown with switchable windows on multiple Spaces
- **THEN** the Spaces are ordered by their Mission Control order, not by which Space is current

#### Scenario: Ordering is stable across reopens
- **WHEN** the overlay is shown, then the active Space changes, then the overlay is shown again
- **THEN** each Space keeps the same relative position across both showings

#### Scenario: Starts on the current Space at its own position
- **WHEN** the overlay is shown
- **THEN** the current Space's window grid is the active (highlighted) one
- **AND** that Space remains at its own position in the Mission Control order rather than being moved to the first position

#### Scenario: Empty Spaces are omitted
- **WHEN** a Space has no switchable windows
- **THEN** it is not shown

#### Scenario: Space switch gated to the grid edge
- **WHEN** the selection is on a visual row that is neither the top nor the bottom row of the current Space's grid and the user scrubs vertically
- **THEN** the selection moves to an adjacent visual row within the same Space and no Space switch occurs
- **AND WHEN** the selection is on the top row and the user scrubs up (or the bottom row and scrubs down), the overlay switches to the adjacent Space

#### Scenario: Indicator reflects position
- **WHEN** there is more than one Space
- **THEN** the overlay shows an indicator of the current Space position and the total number of Spaces

### Requirement: Animated row switching keeps the strip behavior
When the shown Space changes, the overlay SHALL swap to the new Space's window grid with a vertical animation, reset the highlighted card to the first card (bottom-left) of the new Space's grid, and preserve the solved uniform-scale layout, thumbnails, and moving highlight within the new grid. During that animation all cards SHALL translate together as a single group; a window thumbnail that becomes available WHILE the animation is in progress SHALL NOT alter a card mid-animation (which would interrupt the motion), but SHALL be applied once the animation settles. Within a single Space, horizontal and vertical scrubbing SHALL navigate the grid (per the grid-navigation requirement) rather than swapping Spaces.

#### Scenario: Space swap shows the new Space's grid
- **WHEN** the selection moves to an adjacent Space
- **THEN** the grid updates to that Space's windows with a vertical animation and the highlight starts at the bottom-left card (the first window)

#### Scenario: All cards move together; late thumbnails fill in after
- **WHEN** a Space switch is animating and a window's thumbnail finishes capturing partway through the animation
- **THEN** every card translates together for the whole animation (no card snaps to place or changes content mid-motion)
- **AND** the newly captured thumbnail appears on its card once the animation has settled
- **AND** a thumbnail already cached before the switch is shown from the start and animates with its card

#### Scenario: Within-Space behavior is grid navigation
- **WHEN** a Space's grid is shown
- **THEN** horizontal and vertical scrubbing navigate cards within that grid, and the solved scale, thumbnails, and moving highlight behave consistently within it

### Requirement: Overlay panel does not perturb focus arbitration
The overlay panel SHALL use a window level and collection behavior that do not interfere with the WindowServer's focus/Space arbitration, and SHALL never be left ordered-in after a gesture ends.

#### Scenario: Non-interfering window configuration
- **WHEN** the overlay panel is created
- **THEN** it uses a transient window level (above normal windows and the menu bar, not the screen-saver band) and does not use an Exposé-exempt collection behavior

#### Scenario: Panel is always torn down
- **WHEN** a gesture ends by commit, cancel, the touch engine stopping, or the app resigning active
- **THEN** the overlay panel is ordered out (idempotently), never left visible

#### Scenario: Modal alerts are frontmost
- **WHEN** the app shows a modal alert
- **THEN** it activates first so the alert is key and frontmost rather than spinning a modal loop owned by a non-frontmost app

### Requirement: Switcher floats above an open Mission Control
When the switcher is triggered while Mission Control is open (opened by the app's gesture ownership), the overlay SHALL be presented above Mission Control so all cards are fully visible. This elevated presentation (raised window level, Exposé-exempt) SHALL be used **only** while Mission Control is open; when it is not, the overlay SHALL keep its normal arbitration-safe presentation so focus/Space behavior is unchanged.

#### Scenario: Overlay is visible over Mission Control
- **WHEN** Mission Control is open and the user triggers the switcher
- **THEN** the switcher cards render above the Mission Control windows, not behind them

#### Scenario: Normal presentation when Mission Control is closed
- **WHEN** the switcher is triggered without Mission Control open
- **THEN** the overlay uses its normal level/behavior and focus/Space handling is unchanged

### Requirement: Selecting while Mission Control is open dismisses it and focuses the window
When a window is committed in the switcher while Mission Control is open, the system SHALL dismiss Mission Control and then focus the selected window via the robust raise. Dismissal SHALL never itself open Mission Control if it was already closed.

#### Scenario: Commit closes Mission Control and focuses the window
- **WHEN** the user selects a window in the switcher while Mission Control is open
- **THEN** Mission Control closes and the selected window is raised and focused

#### Scenario: Stale state does not reopen Mission Control
- **WHEN** a commit's dismiss runs but Mission Control is no longer open
- **THEN** Mission Control is not opened, and the selected window is still raised and focused

### Requirement: Configuration Hub appears as a switcher card while open
While the configuration Hub window is open (visible), the switcher SHALL include a single synthetic card for the Hub so the user can scrub back to it, even though the app remains an accessory (`LSUIElement`) app with no Dock icon and no Cmd-Tab entry. The Hub card SHALL be injected on purpose and SHALL be the **only** window of the app that appears — the general self-PID exclusion that keeps the app's own overlay panels out of the switcher SHALL remain in force, so no other window of the app (the overlay panels) ever leaks in. When the Hub is not open, no Hub card SHALL appear. The app SHALL NOT change its activation policy to achieve this (no Dock icon, no Cmd-Tab entry are introduced).

#### Scenario: Hub card present while open
- **WHEN** the Hub window is open (visible) and the switcher is triggered
- **THEN** the switcher shows exactly one card for the Hub, titled with the app name followed by " Hub"
- **AND** no other window belonging to the app appears as a card

#### Scenario: No Hub card when closed
- **WHEN** the Hub window is not open (not visible) and the switcher is triggered
- **THEN** no card for the Hub appears, and the app's overlay panels still do not appear

#### Scenario: Accessory mode preserved
- **WHEN** the Hub card is shown or committed
- **THEN** the app's activation policy is unchanged — it remains an accessory app with no Dock icon and no Cmd-Tab entry

### Requirement: Hub card is icon-only with no self-capture
The Hub switcher card SHALL be icon-only: it carries no Accessibility element and no captured thumbnail, and the switcher SHALL render the app icon (its existing no-thumbnail fallback) for it. The Hub window's id SHALL be excluded from the thumbnail seed and prefetch, so no ScreenCaptureKit capture of the app's own window is ever attempted.

#### Scenario: App icon shown, no thumbnail
- **WHEN** the Hub card is rendered
- **THEN** it shows the app icon (no live thumbnail) and a title of the app name followed by " Hub"

#### Scenario: No self-capture is attempted
- **WHEN** the switcher seeds or prefetches thumbnails for the current Space-row that contains the Hub card
- **THEN** the Hub window's id is excluded from both the seed and the prefetch, so no ScreenCaptureKit capture of the app's own window is attempted

### Requirement: Hub card stays on its opened Space and committing focuses the Hub
The Hub window SHALL remain on the Space it was opened on (it SHALL NOT be made to join all Spaces or move to the active Space). The Hub card SHALL appear on the Space-row for the Space the Hub was opened on. Committing the Hub card SHALL focus the real Hub window — bringing the app forward and making the Hub key and front via the app's own-window focus path — switching to the Hub's Space first if it is on a different Space than the active one, exactly as raising any other off-Space window does. Because the focused window is the app's own, the commit SHALL NOT depend on the Accessibility-gated cross-Space raise used for foreign windows.

#### Scenario: Card lands in the Hub's Space-row
- **WHEN** the Hub was opened on a given Space and the switcher is shown with windows across multiple Spaces
- **THEN** the Hub card appears in the Space-row for the Space the Hub was opened on

#### Scenario: Committing focuses the Hub on the current Space
- **WHEN** the Hub card is committed and the Hub is on the currently active Space
- **THEN** the app comes forward and the Hub window becomes key and front

#### Scenario: Committing switches to the Hub's Space when it is elsewhere
- **WHEN** the Hub card is committed and the Hub is on a different Space than the active one
- **THEN** the system switches to the Hub's Space and the Hub window becomes key and front, like raising any other off-Space window

### Requirement: Live preview of the highlighted window

Live preview SHALL remain **ON by default**: while the overlay is open the switcher SHALL continuously re-capture the currently highlighted window and update its card in near-real-time, so a window whose content is changing (video, a scrolling terminal, a running download) is shown live rather than as a single frozen snapshot. At most ONE window SHALL be live-captured at any instant — the highlighted one — and the live focus SHALL follow the selection as it scrubs across the row and between Space-rows.

The live-preview setting SHALL fully gate **all** continuous re-capture — including the eager re-capture kicked on each scrub step, not only the idle timer — so when the setting is off, **no** window is re-captured during a gesture and the switcher shows stable last-good thumbnails. (No default flip and no migration: the default stays on; the setting only gains the property that off means off.)

Live capture SHALL reuse the static thumbnail capture's degraded-frame safety gate (`isOffAllDisplays` / `isStripProxy` / `isDegradedCapture`): a window that is not cleanly presented — parked off every display (Stage-Manager set-aside), a Stage-Manager strip proxy, or the synthetic Hub entry — SHALL NOT be live-captured and SHALL retain its last good static frame. The cleanliness signals SHALL be evaluated against the window's **current** frame (a cheap per-window read), NOT a possibly-stale per-gesture snapshot, so a window that began animating after the snapshot is not captured on its stale full-size frame. Furthermore, while the highlighted window is **in motion** — its current frame still changing tick-to-tick, e.g. morphing between the Stage-Manager strip and the full stage, or animating to or from the Dock — it SHALL NOT be live-captured at all; its last good frame SHALL be retained until the frame holds still, so an in-flight ("sideways") frame is neither shown nor frozen onto its card by scrubbing away before it settles. Live preview SHALL NOT introduce any new permission; when Screen Recording access is absent it SHALL degrade silently to the existing static behavior.

The live layer SHALL be additive over the first-frame bootstrap: opening the overlay still seeds cached static thumbnails and performs the existing one-shot row prefetch, and live re-capture refreshes the highlighted card on top of that. The entire behavior SHALL be gated on the live-preview setting; when the setting is disabled the switcher SHALL behave exactly as the static-only thumbnail strip.

#### Scenario: Highlighted window updates live
- **WHEN** the overlay is open with live preview enabled and the highlighted window's content changes
- **THEN** the highlighted card's thumbnail refreshes to reflect the new content within the capture cadence, without re-creating the strip

#### Scenario: Live focus follows the selection
- **WHEN** the selection scrubs to a different card
- **THEN** the newly highlighted window becomes the live-captured one and the previously highlighted card retains its last captured frame

#### Scenario: At most one window is live
- **WHEN** the overlay is open with live preview enabled
- **THEN** only the currently highlighted window is being re-captured; all other cards hold their last captured (static) frame

#### Scenario: Non-cleanly-presented windows never go live
- **WHEN** the highlighted window is parked off every display, is a Stage-Manager strip proxy, or is the synthetic Hub entry
- **THEN** it is not live-captured and its card keeps its last good static frame (no cropped or sideways image is shown)

#### Scenario: Cleanliness is judged on the window's current frame
- **WHEN** the highlighted window began animating (e.g. toward the Dock) AFTER the per-gesture capture snapshot was taken
- **THEN** the degraded-frame gate is evaluated against the window's current (fresh) frame, not the stale snapshot, so the in-flight window is recognized as not-clean and is not captured on its old full-size geometry

#### Scenario: Window in motion is not captured in flight
- **WHEN** the highlighted window is mid-animation — morphing between the Stage-Manager strip and the full stage, or minimizing toward / restoring from the Dock — so its current frame is still changing from tick to tick
- **THEN** it is not live-captured while in motion and its card keeps its last good frame, for as long as the animation runs
- **AND** scrubbing to another window before it settles does not leave an in-flight ("sideways") frame frozen on its card
- **AND** once the window stops moving, the next tick captures a clean frame

#### Scenario: Toggle off stops all scrub-time re-capture
- **WHEN** live preview is disabled in settings and the user opens the switcher and scrubs across windows
- **THEN** no window is re-captured during the gesture — neither by the idle timer nor on each scrub step — and each card shows its last good thumbnail
- **AND** the switcher otherwise seeds and prefetches thumbnails exactly as before

#### Scenario: Live capture stops on teardown
- **WHEN** the gesture ends by commit, cancel, the touch engine stopping, the app resigning active, system sleep, or the app being disabled
- **THEN** continuous live re-capture stops promptly and idempotently, leaving no capture activity after the overlay is torn down

### Requirement: Window grid of real-proportion cards

The overlay SHALL render the current Space's windows as a wrapped grid of cards, one card per window in snapshot order, filling each visual row left-to-right and stacking the rows bottom-to-top — so the first window (in snapshot order) occupies the BOTTOM visual row and later windows wrap UPWARD. (A single row is unaffected: its first window is leftmost.) Each card SHALL render at its window's true proportion (from the window's real Accessibility frame), not a fixed shape, so a portrait window is a tall-narrow card and a landscape window a wide card. Each card SHALL show the window's thumbnail (or the app-icon placeholder when no thumbnail is available). Within a visual row, cards of differing height SHALL be vertically centered to the row's band height (the tallest card in that row).

#### Scenario: One card per window in order

- **WHEN** the overlay is shown for a Space of N windows
- **THEN** N cards are rendered in snapshot order, each row filled left-to-right with rows stacked bottom-to-top (the first window in the bottom row, later windows wrapping upward)

#### Scenario: First window sits in the bottom row

- **WHEN** the overlay is shown for a Space whose windows wrap into two or more visual rows
- **THEN** the first window (in snapshot order) is in the bottom visual row
- **AND** entering the Space highlights that first window at the bottom-left, with a swipe-up moving toward the top row

#### Scenario: Cards keep their window's proportion

- **WHEN** a card is rendered for a window
- **THEN** the card's width-to-height ratio matches the window's real frame ratio (portrait windows are narrow, landscape windows are wide), rather than a fixed card shape

#### Scenario: Thumbnail or icon placeholder

- **WHEN** a card is rendered
- **THEN** it shows the window's thumbnail image, or the owning app icon as a placeholder when no thumbnail is available

#### Scenario: Mixed-height rows are centered

- **WHEN** a visual row contains cards of differing heights
- **THEN** each card is vertically centered within the row's band (height of the tallest card in that row)

### Requirement: Uniform-scale layout solve

The overlay SHALL size all visible cards by a single shared scale factor applied to every window's real frame, so relative sizes are preserved across the whole grid (a genuinely smaller window appears smaller in both dimensions, as in Mission Control). The scale factor SHALL be the largest value whose wrapped grid still fits the canvas, bounded by a maximum (so one or two windows do not balloon) and a per-card minimum size (so a small window never becomes an unreadable speck). The same metric values SHALL be used to compute the card frames and to size the panel, so the rendered grid and the panel frame cannot diverge.

#### Scenario: One scale factor for all windows

- **WHEN** the grid is laid out for a set of windows of differing real sizes
- **THEN** every card is the same single scale factor times its window's real frame, so their relative sizes match the windows' real relative sizes

#### Scenario: Scale adapts to content density

- **WHEN** a Space contains a much larger window alongside smaller ones
- **THEN** the shared scale shrinks so the grid fits, making every card proportionally smaller
- **AND WHEN** a Space contains only modest-sized windows, the shared scale grows (up to the maximum) so cards are larger

#### Scenario: Minimum card size floor

- **WHEN** the shared scale would render a window below the minimum readable card size
- **THEN** that card is floored to the minimum size rather than shown as a speck

#### Scenario: Single source of truth for card and panel metrics

- **WHEN** the panel size is computed
- **THEN** it derives from the same solved layout (scale, wrapped rows, card frames) that the grid renders from, so the two cannot drift

### Requirement: Grid navigation within a Space

Within a Space, horizontal scrubbing SHALL move the selection among the cards of the current visual row, and vertical scrubbing SHALL move the selection between visual rows. Horizontal movement SHALL stay within the current visual row (it SHALL NOT jump to another row). Moving to an adjacent visual row SHALL land the selection on the first (leftmost) card of that row.

#### Scenario: Horizontal moves within the current row

- **WHEN** the selection is in a visual row and the user scrubs horizontally
- **THEN** the selection moves among the cards of that same visual row and does not jump to another row

#### Scenario: Vertical moves between visual rows

- **WHEN** the user scrubs vertically and an adjacent visual row exists within the Space
- **THEN** the selection moves to that row, landing on its first (leftmost) card

#### Scenario: Selection kept visible when the grid overflows

- **WHEN** the selected card would fall outside the visible canvas because the grid is taller than the canvas
- **THEN** the canvas scrolls so the selected card remains visible

### Requirement: Single highlighted-window title

The overlay SHALL display the title and app icon of the currently highlighted window once, beneath the grid, and SHALL update it as the highlight moves. The title and icon SHALL swap as a hard cut (no fade/crossfade), including when the highlight change accompanies an animated Space switch. Individual cards SHALL NOT each carry a title row.

#### Scenario: Highlighted title shown beneath the grid

- **WHEN** the overlay is shown and a window is highlighted
- **THEN** the highlighted window's app icon and title are shown once beneath the grid
- **AND** individual cards do not each render their own title

#### Scenario: Title follows the highlight

- **WHEN** the selection moves to a different window
- **THEN** the title beneath the grid updates to the newly highlighted window without rebuilding the grid

#### Scenario: Title cuts rather than crossfades

- **WHEN** the highlighted window changes, including during a Space switch's animated reel slide
- **THEN** the title and icon swap instantly (a hard cut), not a fade/crossfade — matching the within-row window-move behavior

### Requirement: Synthetic and frameless cards use a fallback proportion

A card whose window has no real Accessibility frame (the synthetic Hub entry, or a legacy current-Space entry) SHALL be sized using its displayed frame when usable, and otherwise a default proportion near the median card size, so it occupies a sensible grid cell. This SHALL NOT change the Hub card's icon-only rendering or its exclusion from thumbnail capture.

#### Scenario: Frameless card gets a fallback size

- **WHEN** a card's window has no real frame and no usable displayed frame
- **THEN** the card is laid out at a default proportion near the median card size

#### Scenario: Hub card remains icon-only and capture-excluded

- **WHEN** the Hub synthetic card is laid out in the grid
- **THEN** it renders the app icon (no thumbnail) and is still excluded from thumbnail seed and prefetch

### Requirement: Real-proportion grid renders within the live cadence

The real-proportion card grid SHALL render the highlighted window's live updates smoothly at the capture cadence. Card images SHALL be drawn from **display-bounded** bitmaps (sized to what the card shows — see the capture-sizing requirement in window-enumeration-and-raising — rather than the window's full native resolution), and the per-card image resampling cost SHALL be kept proportional to the displayed card size. A card SHALL scale its thumbnail to **fit** (letterbox) within its real-proportion bounds rather than cropping/zooming it to fill, so a capture whose aspect does not match the card — a transitional / in-flight frame that slipped past the capture-side gates — is shown harmlessly reduced rather than smeared into a sideways image; a clean capture (whose aspect matches the card) fills the card edge-to-edge.

#### Scenario: Card image is drawn from a display-bounded bitmap
- **WHEN** a card renders a window's thumbnail
- **THEN** the underlying bitmap it resamples is bounded to roughly the displayed card size (times a Retina headroom), so resampling a large source window does not cost more than the card displays

#### Scenario: A good capture fills its proportioned card without distortion
- **WHEN** a clean, settled capture is shown in its card
- **THEN** it fills the card (which is sized to the window's real proportion) edge-to-edge with no sideways or stretched appearance

#### Scenario: A mismatched-aspect capture letterboxes rather than cropping sideways
- **WHEN** a card's available thumbnail has an aspect ratio that does not match the card's real-proportion bounds (a transitional / in-flight frame that slipped past the capture-side gates)
- **THEN** it is scaled to fit (letterboxed) within the card, not cropped or zoomed to fill — so no sideways or stretched image is ever shown

