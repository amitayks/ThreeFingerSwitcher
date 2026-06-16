## Why

The window switcher renders every window as a fixed-size card with the thumbnail letterboxed inside (`.aspectRatio(.fit)`), so a portrait utility window and a 4K editor look the same size and shape — relative size is lost. And a Space with many windows is crammed into a single horizontal row that scrolls off-screen, so you can't see them all at once. Mission Control already solves both: windows keep their true relative proportions and wrap to fill the screen. The switcher should adopt that spatial model while keeping its ordered, trackpad-scrubbable layout (Mission Control scatters; we stay ordered row-by-row).

## What Changes

- **Real-proportion cards (uniform scale).** Each window renders at its true `realFrame` proportion, scaled by a single global factor `k` shared across all windows in the view — so a small window is genuinely smaller in both dimensions, exactly as in Mission Control. `k` is *solved* (largest value that still fits the canvas), with a min clamp so a tiny window never becomes an unreadable speck and a `k_max` cap so one or two windows don't balloon. Replaces the fixed `cardInnerWidth × cardHeight` + `.fit` letterboxing.
- **Grid wrap.** A Space's windows wrap into multiple visual rows that fill the canvas width, instead of one horizontal scrolling row — so all of a Space's windows are visible at once. Row height = tallest card in that row; shorter cards are vertically centered within the band.
- **2-D grid navigation.** Horizontal scrubbing moves the selection within the current visual row; vertical scrubbing moves between visual rows. A Space switch only happens when vertical travel pushes *past the top or bottom* visual row (was: any vertical step switched Space). The grid stacks bottom-to-top (first window in the bottom row), so entering a Space lands on its first window at the **bottom-left** card — matching the existing column reset, avoiding bounce-back, and mirroring the Space dots that count up from the bottom.
- **Larger centered canvas.** The overlay grows to a large centered canvas (a fraction of the visible frame) that the solved layout fills, instead of the small hug-the-cards strip — bigger, more readable thumbnails. If even at minimum scale the grid overflows the canvas height (many windows), it scrolls vertically.
- **Highlighted-only title.** The per-card title row is dropped (unreadable under small scaled cards); the highlighted window's app icon + title show once, centered beneath the canvas, Mission-Control-style.
- **Unchanged:** the recognizer stays dumb (emits horizontal/vertical steps; the model decides "move grid row" vs "switch Space"); axis-lock; live preview of the single highlighted window; the slide transition between Spaces; the Hub synthetic card (icon-only, falls back to a default proportion since its `realFrame` is `.zero`); non-activating/focus-safe panel behavior.

## Capabilities

### New Capabilities
<!-- None: this refines an existing capability. -->

### Modified Capabilities
- `switcher-overlay`: The thumbnail-strip rendering becomes a wrapped grid of real-proportioned (uniform-scale) cards; the adaptive-width container becomes an adaptive canvas sized to the solved grid; the Space-row display gains intra-Space grid navigation, with Space switching gated to the top/bottom edge rows; card content moves from per-card title to a single highlighted-window title.

## Impact

- **Code:** `Overlay/SwitcherLayout.swift` (fixed metrics → a pure uniform-scale flow-layout solve), `Overlay/SwitcherView.swift` (single `ScrollView` row → wrapped grid of variable cards + highlighted title), `Overlay/SwitcherModel.swift` (`rows = Spaces` → per-Space grid state: `currentGridRow`/`col`, derived visible windows), `Overlay/OverlayController.swift` (panel sizing from the solved grid; `updateRow` semantics), `App/AppCoordinator.swift` (`gestureDidStepRow` decides grid-row move vs Space switch). The `GestureRecognizer` switcher path is unchanged.
- **Data:** uses existing `WindowInfo.realFrame` (AX true frame) for proportion/scale; `SpaceGrouping` still buckets windows by Space.
- **Tunables:** new layout constants (canvas size fraction, `k_max`, min readable card size, inter-card spacing). No new permission, no gesture relocation, no re-login.
- **Tests:** the new pure flow-layout solve and the grid-navigation/edge-to-Space state machine are unit-testable (`swift test`), like `SpaceGrouping`. Onboarding wizard demo (`FirstTouchWizardModel`) uses `setRows`/`setColumn` and must be kept compiling against the model's new shape.
