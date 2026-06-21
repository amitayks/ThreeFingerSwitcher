## 1. Pure picker state machine (Core)

- [x] 1.1 Add `RegionPickerModel` (pure, MLX-free): tracks drag origin / current point / live rect; exposes a single resolve verdict (`.region(CGRect)` vs `.cancel`). (`Sources/.../RegionPicker/RegionPickerModel.swift`.)
- [x] 1.2 Implement the click-without-drag rule: a release whose straight-line travel from the origin is below `minDragDistance` (named constant, 6pt) resolves to `.cancel`; otherwise `.region`.
- [x] 1.3 Unit tests (7): full drag → `.region`; any-direction normalization; tap → `.cancel`; just-below vs just-above the threshold; release-without-begin → `.cancel`; liveRect tracks + clears.

## 2. Region capture (selection I/O)

- [x] 2.1 Change `SelectionService.captureScreenRegion` to capture a **given rectangle** via `SCStreamConfiguration.sourceRect`; exclude our own (`getpid()`) overlay windows + cursor; return PNG.
- [x] 2.2 Return `.unavailable` for a degenerate rect (no full-screen fallback); a cancelled pick never calls capture (the picker resolves `.cancel` without it). Preserve the missing-Screen-Recording `.permissionDenied` outcome (→ executor `.failed`, bounded/non-blocking; no `NSAlert`, no raw text).
- [x] 2.3 Resolve the region against the screen under the drag (single-display v1, documented). Pure `displayLocalRect(forGlobalCocoa:displayFrameCocoa:)` flip is unit-tested (main + secondary-display offset cases).

## 3. Region picker overlay (AppKit — compile-verified; run-verify by user)

- [x] 3.1 Add `RegionPickerOverlay` controller + `RegionPickerCanvas` view: full-screen `.nonactivatingPanel`, `ignoresMouseEvents = false`, never key/main; dims the surface, punches the live selection clear, outlines it, crosshair cursor.
- [x] 3.2 Wire mouse-down/drag/up into `RegionPickerModel`; convert the resolved window rect → global screen rect once at mouse-up; call back `.region(rect)` / `.cancel`.
- [x] 3.3 Synchronous teardown (`orderOut` + `close`), tearing down BEFORE delivering the resolution (so a capture never grabs the dimming surface) — never deferred (Space-switch ghost rule).
- [x] 3.4 Exclude the picker overlay from the capture (its panel is ours → filtered by `getpid()`, and it is ordered out before the grab).

## 4. Executor pre-supplied image

- [x] 4.1 Added `fire(_:screenCapture:)` taking the picker's `ScreenCaptureOutcome` (not raw bytes, so the executor keeps the permission→`.failed` / unavailable→`.noInput` mapping in one place); retained across a same-command language re-run.
- [x] 4.2 Removed the in-executor `captureScreenRegion()` call; capture left the `SelectionProviding` seam entirely (the executor never captures). The `screenRegion` branch now consumes the pre-supplied capture.
- [x] 4.3 Tests: captured image → vision request fired with that image; unavailable / no-capture-supplied → `.noInput`; permission gap → `.failed` naming Screen Recording.

## 5. Launcher orchestration (compile-verified; run-verify by user)

- [x] 5.1 In `LauncherOverlayController.end()` Case 2a, an armed `.aiCommand` with `input == .screenRegion` dismisses the launcher (synchronous `hide()`) and hands off via the new `onScreenRegionCommand` callback (no `onFire`).
- [x] 5.2 New `showCanvas(for:)` re-opens the canvas standalone; the coordinator's `onScreenRegionCommand` captures the region, calls `showCanvas`, and fires the executor with the capture. Canvas resolves via the normal swipe-to-resolve grammar (`onCanvasStateChanged(true)`).
- [x] 5.3 On cancel: no canvas, nothing generated; the front app retains focus (both launcher and picker are non-activating, so nothing to restore).
- [x] 5.4 Non-screen-region AI commands keep today's stay-up-and-stream path unchanged (the new branch is gated on `.screenRegion`).

## 6. Verify

- [x] 6.1 `swift build` + `swift test` green (932 tests, 0 failures; pure model / executor seam / capture-geometry covered). The full `ThreeFingerSwitcher` executable product builds + links (Core + GemmaRuntime/MLX + orchestration) — effective compile-verify of the app.
- [x] 6.2 `openspec validate --strict` passes; spec deltas (new `screen-region-picker` + `selection-io` / `ai-command-band` / `launcher-overlay` deltas) match implementation.
- [x] 6.3 **User run-verified** in a stable-signed build: capture + vision response confirmed working ("the capture and responding working well and the model understand the visual"). Drag-to-capture → canvas streams a grounded result.
