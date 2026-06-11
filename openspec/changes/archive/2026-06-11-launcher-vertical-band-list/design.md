## Context

Today the launcher (`LauncherView`) is a `VStack`: a horizontal tab row of band titles (`tabs`), a divider, then the icon grid (`LazyVGrid`, 6 fixed columns, scrolls past 4 rows). Navigation (`LauncherModel`) is a 2D cursor with `Focus = .headers | .grid`:

- **Horizontal** travel → `stepHorizontal`: on `.headers` it switches the band; in `.grid` it moves within a row.
- **Vertical** travel → `stepVertical`: in `.grid` it moves between rows and, from row 0 up, **rises to `.headers`**; from `.headers` down it drops into the grid at item 0.
- The gesture layer (`GestureRecognizer`) applies a **coarser** step distance (`launcherContextStepDistance`) to the **horizontal** axis only while `focusIsOnHeaders`, so band switching is deliberate; everything else uses the fine `launcherStepDistance`.
- The panel (`LauncherOverlayController.layout`) is a constant-width container whose height grows with the band's item count up to 4 rows. The Clipboard band and the AI canvas swap in their own larger `ClipboardBandLayout` metrics and replace the tabs+grid entirely.

This change rotates the band strip 90°: from a top row to a **left column**, with the content on the right. The grid's internal navigation and scrolling are unchanged; only the relationship between the band strip and the content rotates.

## Goals / Non-Goals

**Goals:**

- Band titles render as a vertical list on the left; the content (6-per-row grid, or the Clipboard master-detail) renders on the right.
- The launcher lands on the **band title** (multi-band) or the **first item** (single band, no list shown).
- Keep the same swipe mechanics: vertical travel on the band list switches bands; horizontal travel crosses between the band list and the content. Grid stepping and grid scrolling are byte-for-byte the same behavior as today.
- The active band title is vertically **centered** in the list; the list scrolls (with existing edge auto-repeat acceleration) when bands overflow.
- The window has a **min-height** that grows toward a **max-height** based on the taller pane; both panes scroll independently and scroll-to-selected on overflow.

**Non-Goals:**

- No change to the AI preview canvas (firing, streaming, swipe-to-resolve, commit/discard) — AI items are ordinary band items; the canvas is a separate surface.
- No change to dwell-to-arm, lift-fires-when-armed, or the activation gesture itself.
- No new band-row visuals (no color swatches) — reuse today's tab text styling.
- No new tunable settings (reuse `launcherStepDistance` / `launcherContextStepDistance`; the band-column width and min/max heights are layout constants like `maxVisibleRows`).

## Decisions

### D1 — Navigation is a spatial transpose, not a mechanic change

The band strip moves from "a row above" to "a column to the left," so the axes that relate it to the grid rotate. The grid-internal axes (rows = vertical, columns = horizontal) do not move.

```
   TODAY (headers row on top)            PROPOSED (band list on left)
 ┌──────────────────────────┐     ┌──────────┬───────────────────────┐
 │ [B1]  B2   B3   …  ← horiz│     │   B1     │  □ □ □ □ □ □           │
 ├──────────────────────────┤     │ ▸ B2 ◂   │  □ □ □ □ □ □   ← horiz │
 │ □ □ □ □ □ □               │     │   B3     │  □ □ □         crosses │
 │ □ □ □ □ □ □   ↕ rows      │     │ (vert =  │   ↕ rows              │
 │ □ □ □        ↑row0→headers│     │  switch  │   (row0 up = clamp)   │
 └──────────────────────────┘     │  band)   │                       │
                                  └──────────┴───────────────────────┘
```

| Action | Today | Proposed |
|---|---|---|
| Switch band | horizontal on `.headers` (coarse) | **vertical** on the band list (coarse) |
| Enter the grid | vertical **down** from headers | horizontal **right** from band list (fine) |
| Leave the grid to bands | vertical **up** from row 0 | horizontal **left** from column 0 (fine) |
| Step within a grid row | horizontal | horizontal (unchanged; col-0 left now exits) |
| Step between grid rows | vertical | vertical (unchanged; row-0 up now clamps) |

`Focus` is renamed in spirit from `.headers` to `.bands` (the cursor is on the band list). Crossing into the grid is a single **fine** step ("one millimetre right"); switching bands keeps the **coarse** deliberate step so a flick doesn't blow through bands.

**Alternative considered:** keep band switching on the horizontal axis (a vertical *visual* list navigated horizontally, like a centered picker driven by left/right). Rejected: it collides with "move right to reach the first item" and reads as spatially backwards (you'd move sideways to scroll a vertical list).

### D2 — The deliberate band-step gate moves with the band axis (the one gesture-layer change)

`GestureRecognizer` currently gates the **horizontal** accumulator with the coarse `launcherContextStepDistance` while `focusIsOnHeaders`. Because band switching is now **vertical-on-the-band-list**, that coarse gate moves to the **vertical** accumulator when the cursor is on the band list; the horizontal accumulator is always the fine item-step. `launcherFocusIsOnHeaders()` becomes a "focus is on the band list" query (rename `focusIsOnHeaders` → `focusIsOnBandList`). This is the only change to the gesture layer — the swipe detection, thresholds, carry, and edge detection are untouched, satisfying "the horizontal swing should not change."

**Alternative considered:** keep the recognizer 100% untouched and accumulate the coarse band-step inside `LauncherModel` instead. Rejected: it duplicates the carry/threshold logic the recognizer already owns and splits the deliberate-step concept across two layers.

### D3 — Edge auto-repeat acceleration is reused as-is

`edgeInterval` / the edge timer are axis-agnostic. With band switching on the vertical axis, holding a **vertical** edge while focused on the band list auto-repeats *band switching* with the existing acceleration ramp — no change to `edgeInterval`. Holding a horizontal edge on the band list crosses into the grid once, then naturally continues as grid item auto-repeat (focus is now `.grid`). In the Clipboard band, horizontal auto-repeat stays suppressed (horizontal is the deliberate pin / cross-to-band-list), vertical auto-repeat scrolls entries — same as today's suppression rule.

### D4 — Window sizing: min-height grows to max-height, both panes scroll

`layout()` becomes: `width = bandColumnWidth + contentWidth` (content = grid container, or Clipboard metrics when the active band is Clipboard); `height = clamp(max(bandListContentHeight, contentHeight), minHeight, maxHeight)`. Both the band list and the content `ScrollView` scroll independently; each uses `scrollTo(selected)` so the focused band title / focused item stays visible. The band list specifically keeps the **active** title centered (`anchor: .center` on band change). `tabsHeight` is dropped from the grid height math.

**Single band:** no band column — `width = contentWidth`, and the launcher lands `Focus = .grid`, item 0 (today's behavior). The band list and its centering only exist when `bandCount > 1`.

### D5 — Clipboard band under the new shell

When the Clipboard band is the active band, the **right** pane is its master-detail (key list + value preview) at `ClipboardBandLayout` width; the left band list stays. Horizontal **right** from the band list crosses into the key list; vertical scrolls entries; horizontal **left** from the key list returns to the band list (this **replaces** today's "left = previous band"). The deliberate **right** pin excursion is preserved (there is no navigable pane to the right of the key list, so a deliberate right flick still means "pin"). The AI canvas remains a full-surface replacement, unchanged.

## Risks / Trade-offs

- **[Lost the instant "fire app 1" path]** Multi-band now lands on a title, so the fastest open-and-hold-to-fire flow gains one rightward step. → Accepted by the user as the deliberate trade-off; single-band setups keep the instant path.
- **[Gesture-layer axis flip done in the wrong place]** If the coarse band-step gate is left on the horizontal axis, band switching becomes twitchy (a flick jumps many bands) and crossing into the grid becomes sluggish. → D2 specifies the gate moves to the vertical axis on the band list; cover with the carry/threshold path that today protects horizontal band switching.
- **[Height churn while scrolling bands]** If the panel animated its height per the active band's item count, switching bands would jitter the frame. → D4 sizes to a stable max of the two panes within min/max bounds and scrolls inside, rather than resizing per band.
- **[Clipboard "previous band" muscle memory]** Users who left-flicked to leave the Clipboard band now land on the band list instead of the previous band. → Documented spec change; the result (back to band list, then vertical to any band) is more general, not just "previous."
- **[Centering vs scroll-to-item fighting]** The band list wants the active title centered while the grid wants the selected item visible; they're independent panes, so their scroll targets must not be wired to a single `onChange`. → Drive each pane's scroll from its own state (band index for the list, selected index for the grid).
