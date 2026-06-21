## Why

A screen-region (vision) command today captures the **whole main display** as a working floor — there is no way to say "ask about *this* part of the screen." The interactive region picker was always the intended slice (deferred while the AI runtime was built; `SelectionService.captureScreenRegion` carries the explicit "the picker is a later slice" note). This adds it: fire a vision command, the launcher gets out of the way to reveal the desktop, drag a rectangle over exactly what you mean, and that region streams into the canvas.

## What Changes

- Add a new interactive **region-picker overlay**: a focus-preserving, mouse-interactive, ghost-safe overlay that dims the screen, shows a crosshair + live selection rectangle, and captures the dragged rectangle as PNG bytes via the held Screen Recording permission.
- **Cancel without a keypress:** a **click without dragging** (a zero / near-zero-area rectangle) defuses the picker and returns to the front app — no canvas, no generation. Honors the app's no-keypress rule.
- **Re-order screen-region acquisition.** Firing a `screenRegion` command now **dismisses the launcher first**, runs the picker over the revealed desktop, and only **then** opens the canvas with the pre-captured image — replacing today's open-canvas-then-grab-full-display flow. This is an exception *within* the existing AI-command "don't dismiss on fire" exception.
- The **executor accepts a pre-supplied image** for screen-region commands and skips its own capture.
- **No new permission** (reuses Screen Recording), **no gesture relocation**, **no re-login**. The picker is cursor-driven (the mouse-interactive-overlay precedent set by the Dock previews); teardown is synchronous (the Space-switch ghost rule).

## Capabilities

### New Capabilities

- `screen-region-picker`: the interactive drag-rectangle capture surface — present over the revealed desktop, drag-to-select with a live rectangle, **click-without-drag to cancel**, capture the designated region as PNG, focus-preserving and synchronously torn down.

### Modified Capabilities

- `selection-io`: screen-region capture is the **user-designated rectangle** from the picker (not the full display); a cancelled pick yields **no image** (not an empty/blank capture).
- `ai-command-band`: a `screenRegion` command runs the picker **before** the canvas; the executor receives a **pre-supplied** image; a cancelled pick aborts the command (no "no input" model run).
- `launcher-overlay`: a screen-region AI command's armed lift **dismisses** the overlay and runs the picker, then opens the canvas on capture — an exception inside the AI-command exception to order-out-before-fire.

## Impact

- **Code:** new `RegionPickerOverlay` + pure picker state machine (Overlay/, following the `DockPreviewOverlay` mouse-interactive pattern); `SelectionService.captureScreenRegion` → region-specific capture (rect → image); `AICommandExecutor` (pre-supplied-image path); `LauncherOverlayController.end()` (dismiss → picker → canvas orchestration).
- **No new permission, no new dependency.**
- **MLX-free Core**: the picker hit-test / drag / cancel state machine is pure and `swift test`-able; the live overlay + ScreenCaptureKit region grab need the real app (compile-verify via `xcodebuild`, run-verify by the user).
