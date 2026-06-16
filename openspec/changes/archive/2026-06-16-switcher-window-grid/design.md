## Context

The switcher overlay (`Overlay/SwitcherView.swift` + `SwitcherModel` + `SwitcherLayout` + `OverlayController`) renders one Space at a time as a single horizontal `ScrollView` of **fixed-size cards** (`cardInnerWidth 200 × cardHeight 150`), with each thumbnail letterboxed inside via `.aspectRatio(.fit)`. Navigation is an odometer in `GestureRecognizer.update`: horizontal travel → `gestureDidStep` (column within the Space), vertical travel → `gestureDidStepRow` (switch Space). `SpaceGrouping.group` buckets the flat all-Spaces snapshot into Space-rows in Mission Control order.

The model is a clean pure-model / dumb-view / dumb-recognizer split, and `WindowInfo.realFrame` already carries each window's true (Accessibility) size — so the data needed for Mission-Control-style proportions is present. This change is the rendering + navigation layer only; enumeration, raising, focus arbitration, live preview, and the recognizer's odometer are untouched.

Decisions already made with the user: **uniform scale** (one global factor, true relative sizes, min-clamped) over uniform-height; and **reset-to-row-start** column behavior on any row change over nearest-column tracking.

## Goals / Non-Goals

**Goals:**
- Each window renders at its true proportion, scaled by one shared factor `k`, so relative *size* (not just shape) matches Mission Control.
- A Space's windows wrap into a grid that fills the canvas, so all are visible at once (no horizontal scroll-off).
- 2-D grid navigation within a Space; Space switching only at the top/bottom visual-row edge.
- Keep the pure-model / testable-layout discipline: the wrap + scale solve and the nav state machine are unit-testable, no SwiftUI geometry readback.
- Preserve focus-safety, live preview, the slide-between-Spaces transition, and the synthetic Hub card.

**Non-Goals:**
- Free 2-D scatter (we stay ordered, row-by-row — that is the whole point vs Mission Control).
- Drag/rearrange, close-from-switcher, or any window mutation.
- Per-card live title or hover affordances (mouse-interactive overlay is out of scope; the panel stays non-activating and pointer-ignoring).
- Changing the recognizer's odometer, axis-lock, enumeration, or raise paths.

## Decisions

### D1 — Uniform scale, *solved* to fit the canvas
Every card is `k·Wᵢ × k·Hᵢ` from `realFrame`, with one `k` for all windows in view. Because the canvas is bounded, `k` is not a constant — it is the **largest value whose flow-wrapped grid still fits the canvas height**. Wrapping is a step function of `k` (a bigger `k` means fewer cards per row, more rows, more height), so `k` is found by a short search (e.g. binary search over `[k_min, k_max]`, computing the wrapped height at each candidate). This single solve delivers relative fidelity, no-overflow, and adaptive density (all-small Space scales up toward `k_max`; a 4K window present scales everything down) in one place.

- **Clamps:** `k ≤ k_max` (one or two windows don't balloon); any card that solves below `minCardSize` is floored to it (a tiny palette stays usable — the one place strict uniformity bends, by design). If even at `k_min` the grid exceeds the canvas height (e.g. ~40 windows), the canvas **scrolls vertically** rather than shrinking further.
- **Row band height** = the tallest card in that visual row; shorter cards are vertically centered within the band.
- **Bottom-to-top stacking:** `wrap` produces rows in flow order (first line first); `solveGrid` then **reverses** them into visual top-to-bottom order, so the first window (index 0 — frontmost/MRU) lands in the **bottom** visual row and later windows wrap upward. Entry lands there (bottom-left) and a swipe-up walks older windows toward the top edge, mirroring the Space dots that count up from the bottom. A single row reverses to itself. Navigation is unchanged — `rows` is still visual top-to-bottom, which is what `currentGridRow` / `moveVertical` (up = row−1) already assume; only `currentGridRow` on entry is now the last row instead of 0.
- *Alternatives rejected:* **uniform height / aspect width** (loses relative size — explicitly declined); **per-row independent scale** (breaks cross-row size comparison — a window looks bigger or smaller depending on which row it wrapped into).

### D2 — One pure flow-layout solve as the single source of truth
A new pure function (in `SwitcherLayout`, mirroring the `LauncherGridLayout` precedent) takes the visible windows' real sizes, the canvas size, and spacing, and returns: the chosen `k`, `gridRows: [[Int]]` (window indices per visual row), each card's frame, and the total content size. `SwitcherView` renders rows from this; `OverlayController` sizes the panel from its total size. Computing the wrap in the model (not via SwiftUI's `Layout`/geometry readback) keeps navigation and panel-sizing deterministic and unit-testable, and avoids the readback races the codebase already avoids elsewhere (the Files cache, BubbleMorph).

### D3 — Model reshape: per-Space grid state
`SwitcherModel` keeps `rows = Spaces` (from `SpaceGrouping`) and `currentRow = current Space`. New per-Space view state: the current Space's windows, the computed `gridRows`, and the selection as `(currentGridRow, col)`. `selectedIndex` (a flat index into the current Space's windows) stays a derived/published value so the existing highlight binding, live-preview "highlighted window," and thumbnail prefetch keep working unchanged. Entering a Space resets selection to the first window (`selectedIndex = 0`); because the grid stacks bottom-to-top (the solve reverses the flow rows into visual order — see D1), that first window sits in the **bottom** visual row, so the reset lands the highlight at the bottom-left.

### D4 — Navigation: recognizer stays dumb, model decides edge-vs-Space
The recognizer is unchanged: horizontal → `gestureDidStep(dir)`, vertical → `gestureDidStepRow(dir)`. The semantics move into the model/coordinator:
- **Horizontal** moves `col` within the current visual row; clamps at the row's ends (or wraps within the row if `wrapAtEnds`). It does not jump rows.
- **Vertical** moves `currentGridRow`. When a vertical step is requested while already on the **top** row (up) or **bottom** row (down), it instead switches Space (previous/next), landing on the first window (bottom-left) of the new Space. This gives clean carry: one step lands on the edge row, the *next* step crosses to the adjacent Space — no double action.
- `AppCoordinator.gestureDidStepRow` asks the model "move grid row in this direction; did it cross the edge?" and only then calls the Space switch (re-prefetch + live-session refresh, as today).

*Alternative rejected:* nearest-column landing on row change (declined by the user; reset-to-start removes the need to track an x-position).

### D5 — Canvas sizing resolves the chicken-and-egg
Panel size drives `k`, and `k` drives content size. Resolved by fixing the canvas first: the canvas target is a fraction of the screen's visible frame (default ~85% width × a bounded height). Solve `k` against that target, then **hug the visible container to the current Space's actual grid size — on BOTH axes** (≤ the target) so a partial last row leaves no dead space below and a narrow Space yields a narrow, centered container rather than one stretched to the full canvas width. (The transparent NSPanel behind it stays sized to the *largest* Space so the all-Spaces reel never resizes mid-switch; only the visible material container hugs — the title row is bounded to the grid width, not `.infinity`, or it would stretch the container back to the panel width.) Overflow beyond the target height scrolls vertically inside the fixed canvas. This replaces today's "hug a single row of cards" sizing in `OverlayController.layout`.

### D6 — Highlighted-only title
Per-card titles are dropped (unreadable under small scaled cards and visually noisy). The highlighted window's app icon + title render once, centered beneath the canvas (Mission-Control idiom), bound to `selectedIndex` so it updates as the highlight moves without rebuilding the grid.

### D7 — Frame fallback for synthetic / frameless cards
`realFrame == .zero` (the Hub synthetic entry, legacy current-Space path) falls back to `frame` when it is sane, else a default 16:10 proportion sized near the median card. The Hub card stays icon-only and excluded from capture, exactly as today; it just occupies one proportioned grid cell.

## Risks / Trade-offs

- **A tiny window becomes a speck / a huge window dominates** → `minCardSize` floor and `k_max` cap; both feel-tunable constants.
- **Boundary double-action (move row AND switch Space on one step)** → the model returns whether the step crossed the edge; the coordinator switches Space only on the crossing step (D4), so each discrete odometer step does exactly one thing.
- **Relayout strobe when `k` or wrap changes** → keep the single sliding highlight (do not per-card animate); this is the documented Files `FilesRowHighlight` landmine in another surface. The grid container may bubble-morph as a whole, not per card.
- **First-session reel "snap" on preview-bearing Spaces (the real cause)** → on the first visit to a Space, thumbnail captures complete *asynchronously, mid-slide*. Each completion is a `setThumbnail` `@Published` mutation that re-evaluates the whole `SwitcherView` body, re-applying the reel `.offset(y: reelOffset())` in that **non-animated** transaction — which **cancels/snaps the in-flight `withAnimation` slide** to its target. So a Space that has preview-apps (a capture lands during the slide) jumps to place while an icon-only Space (no mid-slide capture) slides cleanly; after the first run everything is cached/seeded before the slide, so nothing lands mid-slide and it's buttery. **Fix — freeze, fill in after:** `SwitcherModel` BUFFERS `setThumbnail` while a slide is animating (`freezeThumbnails`) and flushes the buffer in one mutation once it settles (`flushThumbnails`). `OverlayController.beginSlideFreeze()` holds the freeze for the slide's `slideDuration` (re-entrant: a fast follow-up switch reschedules the flush; `hide()` flushes+cancels). The coordinator calls it in `switchSpace` AFTER seeding the new Space's cached thumbnails — so cached previews are present and slide WITH the cards, and only the async captures that would otherwise land mid-slide are held back to cut in afterward. **Seeds bypass the freeze** (`SwitcherModel.seedThumbnail`, used by `ThumbnailService.seed`): a cached frame is always applied inside a switch's own animated tick (so it can't snap the slide) and must show the instant the Space slides in — including during *fast consecutive* switches, where the PRIOR switch's freeze is still holding when the next switch seeds. Routing the seed through the frozen `setThumbnail` was the bug that made each subsequent Space's cached previews appear a beat late; only live captures (the `onThumbnail` path) are frozen.
- **Seed every Space on open, not on first visit** → the reel builds all Spaces' cards eagerly, but their cached previews were only seeded when a Space became current, so on a Space's FIRST visit its cards (and their highlight border, which is part of the card) re-rendered icon→thumbnail in the switch tick — a visible "rebuild on first visible," after which the persisted thumbnails made re-visits a pure slide. `AppCoordinator.seedAllRows()` (called from `gestureDidActivate` on open) seeds the cached thumbnails for EVERY Space's windows up front, so switching to any Space is a pure slide with nothing left to rebuild. Off-screen Spaces can't be freshly captured anyway, so cache is their only preview source; `SwitcherModel.seedThumbnail` is idempotent (`===` guard) so re-seeding an already-present frame doesn't republish. With no `@Published` change during the slide, every card translates as a rigid group; the plain `withAnimation` in `updateRow` is enough (no value-keyed animation / `disablesAnimations` / per-card `.transaction` — those were tried and reverted: a per-card `.transaction { $0.animation = nil }` actually SNAPPED the preview cards individually).
- **First-session capture latency (secondary, warmed at launch)** → ScreenCaptureKit's cold start (framework init + XPC handshake on the first `SCShareableContent` enumeration + first `SCScreenshotManager` capture) makes the first captures slow; `ThumbnailService.warmUp()` (a background enumeration + one tiny throwaway capture from `AppCoordinator.start()`, no-op without Screen Recording permission) pays it before the first trigger, and `OverlayController.prewarm()` renders the panel once off-screen so the hosting view's layer is warm. Neither is load-bearing now that the slide can't be snapped (the freeze handles correctness regardless of capture timing); both just reduce first-open jank.
- **Many windows overflow even at `k_min`** → vertical scroll inside the canvas, with the highlight kept visible (extends the existing "selected card kept visible" auto-scroll to the vertical axis). Rare in practice.
- **Onboarding wizard demo** (`FirstTouchWizardModel`) drives the model via `setRows`/`setColumn` → must be updated to the reshaped model so it keeps compiling and demoing.
- **Focus arbitration / Mission-Control-float / Hub paths unchanged** → this is a rendering+nav change; the panel stays a non-activating, pointer-ignoring `.nonactivatingPanel`, so the focus and Space-arbitration requirements are not in scope and must not regress.

## Open Questions

- Concrete feel constants — canvas fraction, `k_max`, `minCardSize`, inter-card/row spacing — to be tuned in-hand after first build; whether any are surfaced on the Hub.
- Whether horizontal should clamp at a visual row's end (default, pure-grid feel) or snake into the next row; default is clamp/within-row-wrap.
