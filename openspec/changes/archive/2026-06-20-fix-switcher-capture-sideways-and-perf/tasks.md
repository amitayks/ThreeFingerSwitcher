## 1. Geometry gate — the only piece already landed (verify, don't redo)

- [x] 1.1 `ThumbnailService.cleanScaleThreshold = 0.85`; both gates raised `0.5 → 0.85`; `&&` → `||` (either dimension, since the strip⇄stage morph also changes aspect). Present in `ThumbnailService.swift` + `OffSpaceFidelityTests.swift`; `swift build`/`swift test` green. _(This is the sole survivor of the earlier exploration — everything below was reverted from code and is re-scoped to B+C.)_
- [x] 1.2 Keep it as the **scaled / strip-proxy backstop** under the motion gate — it catches the phase the geometry signal *can* see; D2 (motion) layers on top for the bounds-normal / pixels-tilted phase. No code change.

## 2. Motion-gate the capture against the FRESH frame (D1 — primary sideways fix)

- [x] 2.1 Add `ThumbnailService.liveBounds(of:)` — a cheap single-id `CGWindowListCopyWindowInfo` read of the window's current frame.
- [x] 2.2 In `liveCapture`, run `isDegradedCapture` against the **fresh** `liveBounds` frame, not the `prepareLiveSession` snapshot; fall back to the snapshot only when the live read is unavailable (so a window that began animating after the snapshot is gated on live geometry).
- [x] 2.3 Add the pure motion gate `liveFrameSettled(previous:current:)` + a per-session `liveBoundsSeen` map: capture only when the fresh frame is **unchanged since the previous observation**; a first observation defers one tick. Clear `liveBoundsSeen` in `endLiveSession`.
- [x] 2.4 Apply the motion gate in `liveCapture` so an in-flight window is never captured (and so scrubbing away cannot freeze a transitional frame on its card).
- [x] 2.5 `OffSpaceFidelityTests`: `liveFrameSettled` cases — first observation defers, unchanged settles, changed defers.

## 3. Protect bystander windows on the one-shot open prefetch (D2 — the Terminal fix)

- [x] 3.1 `ThumbnailService.prefetch`: skip any window that **already has a cached frame** — only never-seen windows are captured (still behind the geometry gate), so a previously-seen bystander (Terminal) keeps its good cached frame when the switcher opens mid-animation. Continuous refresh of the *highlighted* window stays on (the live path), so this is not "stop re-capturing."
- [x] 3.2 `OffSpaceFidelityTests` (or `ThumbnailServiceTests`): a window with a cached frame is not re-captured by `prefetch`; a never-seen window still is.

## 4. Make the "Live preview" toggle fully gate re-capture (D3 — fix the leak)

- [x] 4.1 Gate the scrub-step `AppCoordinator.tickLivePreview` on `settings.livePreviewEnabled` at its call sites (`gestureDidStep`, `gestureDidStepRow`, `switchSpace`) / inside `tickLivePreview`, so the toggle off means zero re-capture during a gesture (today only the idle timer is gated — the scrub path leaks via `liveCapture`'s enumeration fallback).
- [x] 4.2 Confirm the default is unchanged: `AppSettings.Defaults.livePreviewEnabled = true`. **No migration, no default-off** (that path is rejected — see design).

## 5. Render `.fit` not `.fill` — letterbox safety net (D4)

- [x] 5.1 In `SwitcherView.card(...)`, change the thumbnail `aspectRatio(contentMode: .fill)` → `.fit`. A clean capture still fills the real-proportion card edge-to-edge; only a wrong-aspect transitional frame letterboxes (harmless). Update the card doc comment that currently says "no `.fit` letterboxing."

## 6. Bound capture resolution to the display target (D6 — perf)

- [x] 6.1 Replace `thumbnailMaxSize = 1100×700` with a cap proportional to the displayed card size × a bounded Retina headroom (start near `600×400`); keep `streamConfiguration(for:)` capping to it.
- [x] 6.2 Extract pure `captureDimensions(windowSize:backingScale:cap:)` and add `OffSpaceFidelityTests` cases (a 4K window is capped; a small window is not upscaled).

## 7. Lighten the per-frame render (D7 — perf)

- [x] 7.1 In `SwitcherView.card(...)`, drop `.interpolation(.high)` → `.medium` (now on the smaller D6 bitmap).
- [ ] 7.2 If still heavy after 6 + 7.1, evaluate `.drawingGroup()` on the reel / per-card image scoping (D7b) — measured only, do not ship blind. _(Needs the signed app to measure.)_

## 8. Diagnostic logging

- [x] 8.1 **Keep** the `TFS_THUMB_LOG` probe in `ThumbnailService` (env-gated, zero cost when unset) — it is the validation tool for the motion gate against real Stage-Manager frames. Revisit removal only after Section 9 confirms the fix in-app.

## 9. Verify in-app (needs the signed app — your Terminal)

- [ ] 9.1 `INSTALL=1 ./scripts/build-app.sh` (also clears the poisoned in-memory cache). Repro with Stage Manager on: switch VSCode → Telegram, **immediately** open the switcher; confirm Terminal (bystander) and any scrubbed-onto window hold their last good frame and never show a sideways frame, then capture cleanly once settled. With `TFS_THUMB_LOG=1`, confirm in-flight frames are skipped and steady-state captures land clean.
- [ ] 9.2 Confirm live preview still updates the highlighted window once it settles (the B guarantee — live previews not sacrificed).
- [ ] 9.3 Confirm the grid renders smoothly after the perf items (6 + 7.1).

## 10. Validate, sync, archive

- [x] 10.1 `swift build --target ThreeFingerSwitcherCore` && `swift test` green (903 tests, 0 failures — +9 new).
- [x] 10.2 `openspec validate fix-switcher-capture-sideways-and-perf --strict` — valid.
- [ ] 10.3 Sync the deltas into `openspec/specs/switcher-overlay` and `openspec/specs/window-enumeration-and-raising`; archive the change. _(After Section 9 confirms in-app.)_
