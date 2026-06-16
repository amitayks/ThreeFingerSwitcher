## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Moving highlight tracks selection
The overlay SHALL visually highlight the currently selected card and SHALL update the highlight in real time as the selection index changes during scrubbing, across both horizontal (within-row) and vertical (between-row) movement.

#### Scenario: Highlight follows scrub
- **WHEN** the selection index changes during scrubbing
- **THEN** the highlight moves to the newly selected card without re-creating the grid

#### Scenario: Selected card kept visible
- **WHEN** the selected card would fall outside the visible area, horizontally or vertically
- **THEN** the canvas scrolls so the highlighted card remains visible

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

## REMOVED Requirements

### Requirement: Thumbnail strip with cards
**Reason**: Replaced by the wrapped, real-proportion window grid — the single horizontal strip of fixed-size cards is superseded by the "Window grid of real-proportion cards" and "Uniform-scale layout solve" requirements.
**Migration**: No data migration. The strip's "one card per window" and "card content" behaviors are carried forward by the new grid requirements; the per-card title is replaced by the "Single highlighted-window title" requirement.
