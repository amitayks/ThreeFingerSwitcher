## Context

`SelectionService.captureScreenRegion()` exists but captures the **whole main display** as a "basic working floor," with an explicit code note that the interactive region picker is a later slice. The vision downstream is finished: `LLMRequest.image`, `GemmaMLXRuntime` multimodal, capability routing, the seven `.screenRegion`/`.previewOnly` Vision presets, and the streaming canvas.

Today's screen-region flow (per `launcher-overlay`): firing an AI command is an exception to order-out-before-fire — the overlay **stays up**, the canvas opens immediately, and the executor calls `captureScreenRegion()` itself (excluding our own overlay windows). This change inverts that ordering **for screen-region commands only**: dismiss the launcher to reveal the desktop, run an interactive picker, then open the canvas on the captured region.

The interactive-overlay primitive is already proven: `DockPreviewOverlayController` is the one mouse-interactive (`ignoresMouseEvents = false`), focus-preserving, synchronously-torn-down overlay. The picker follows that pattern.

## Goals / Non-Goals

**Goals:**
- Fire a vision command → launcher gets out of the way → drag a rectangle over the desktop → that region streams into the canvas.
- **Click without dragging cancels** (no keypress), restoring the front app with no canvas and no generation.
- Reuse Screen Recording; no new permission, no gesture relocation, no re-login.
- Pure picker state machine in MLX-free Core (hit-test / drag / cancel), `swift test`-able; only the live overlay + region capture need the real app.

**Non-Goals:**
- Multi-rectangle / freehand / window-snap selection (single drag rectangle, v1).
- Annotation or editing of the captured region.
- Changing the resolve grammar of the canvas itself (still the established swipe-to-resolve).
- A keyboard Escape cancel (no-keypress rule).
- Replacing the clipboard-image acquisition path (separate change).

## Decisions

**1. Cursor-driven picker overlay, modeled on `DockPreviewOverlay`.**
A new `RegionPickerOverlay` panel: `.nonactivatingPanel` (front app stays key), `ignoresMouseEvents = false`, `acceptsMouseMovedEvents = true`, never key/main (no keyboard), dims the screen and draws a live selection rectangle + crosshair. The pure brain is a `RegionPickerModel` (drag start / current / committed rect / cancel verdict) so geometry and the cancel rule are unit-tested without AppKit. *Alternative considered:* a trackpad-gesture region selection — rejected; region selection is inherently a pointing task, and the fingers are already lifted after the firing lift.

**2. Inverted ordering for screen-region commands — an exception inside the AI-command exception.**
In `LauncherOverlayController.end()`, when the armed item is an `.aiCommand` whose `input == .screenRegion`: **dismiss the launcher** (synchronous teardown — the ghost rule), show the `RegionPickerOverlay` over the revealed desktop, and **defer** `enterCanvas` until capture. On capture → fire the executor with the **pre-supplied image** and open the canvas. On cancel → restore the front app, open nothing. Non-screen-region AI commands keep today's stay-up-and-stream behavior unchanged.

**3. Executor accepts a pre-supplied image.**
Add a path (e.g. `fire(_:image:)` or threading an optional captured image into `run`) so a screen-region command **skips its own `captureScreenRegion()`** when the picker already produced the image. The capture now happens *before* the canvas exists, so the executor must not re-capture. The existing in-executor full-display capture is removed from the screen-region path (the picker is the sole region source).

**4. Click-without-drag cancels (zero/near-zero-area rule).**
A mouse-up whose drag rectangle is below a small area/Δ threshold (a tap, not a drag) is a **cancel**, not a capture — matching ⌘⇧4 muscle memory (press-and-release without dragging aborts). The threshold lives in the pure model and is the single cancel verdict; there is no keyboard path.

**5. Region capture via ScreenCaptureKit, our overlay excluded.**
`captureScreenRegion` becomes region-specific: given the picker's committed rect (Cocoa global coords), capture just that rectangle (crop the display capture, or an SCK rect filter), excluding our own overlay windows and the cursor, returning PNG. A cancelled pick returns **no image** (not a blank/empty capture).

**6. Synchronous teardown everywhere (ghost rule).**
The choreography is hide-launcher → show-picker → hide-picker → show-canvas — every overlay teardown stays synchronous (`orderOut`/`close`), per the documented Space-switch ghost-on-leave landmine that already governs the launcher, Files band, and Dock preview overlays.

## Risks / Trade-offs

- **Mouse↔trackpad context switch mid-flow** (3-finger lift to fire → cursor drag to select → 2-finger swipe to resolve the canvas) → inherent to a pointing task; prototype the *feel* early, keep the picker visually obvious (dim + crosshair) so the mode change is unmistakable.
- **Accidental tiny drag reads as a real capture (or vice-versa)** → tune the cancel area/Δ threshold in the pure model; cover both sides with unit tests (just-below = cancel, just-above = capture).
- **Picker overlay captured in its own screenshot** → exclude our windows from the SCK filter (the existing `captureScreenRegion` already excludes `getpid()` windows) and/or order the picker out before the grab.
- **Ghost overlay on a Space switch** → all three teardowns synchronous; never defer the picker's `orderOut` behind an animation.
- **Multi-display: rectangle spanning displays / picker on the wrong screen** → resolve the region against the screen under the drag; v1 may scope a pick to a single display and document it.
- **Permission missing at capture time** → surface the existing Screen-Recording "permission required" failure as a bounded, non-blocking card (the AI/file error convention), never an `NSAlert`.

## Open Questions

- Multi-display spanning: scope v1 to the display under the drag start, or support a cross-display rectangle? (Lean single-display for v1.)
- Should the picker offer a one-gesture "whole screen" shortcut (e.g. a click in a corner, or Esc-equivalent) to recover today's full-display behavior, or is dragging the full screen good enough? (Lean: dragging is enough for v1.)
- Exact cancel threshold value (area in points / min drag Δ) — pick a default, expose as a tunable only if testing shows it needs one.
