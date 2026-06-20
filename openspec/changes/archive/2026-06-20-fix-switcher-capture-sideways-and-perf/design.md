## Context

The Mission-Control real-proportion grid (`ecc66e9`) reshaped how the switcher captures and renders thumbnails and reintroduced a "sideways" frame. After an extended exploration, the root cause and the fix shape are now settled.

**Root cause — capturing mid-animation, not a wrong threshold.** Stage Manager (and Mission Control) animate a window between the off-stage strip and the full stage with a **perspective + aspect morph** (strip aspect ≈ 1.15 → stage aspect ≈ 1.59). For part of that animation the window's reported **bounds** are already (near) full size while its rendered **pixels** are still tilted / wrong-aspect. ScreenCaptureKit captures the pixels; the degraded gate inspects the bounds. So a geometry gate is structurally blind to this phase:

```
   reported frame  ≈ 100%   (geometry says "settled")   →  GATE PASSES ✅
   rendered pixels = mid-morph, tilted / wrong-aspect    →  CAPTURED FRAME IS BAD ❌
```

No threshold value closes this — `0.85`, `0.95`, `0.99` all pass a window whose *bounds* are correct but whose *pixels* are still in flight. The `.fill` + crop card then zooms that frame to the window's true proportion, turning a harmless letterbox into a glaring sideways smear.

**Two capture paths hit the window at the moment of risk:**

```
                       SWITCHER OPENS  (right after an app switch)
                              │
            ┌─────────────────┼──────────────────┐
            │                 │                  │
       prefetch()        liveCapture()      liveCapture()
       one-shot,         on each scrub      idle 0.1s timer
       ALL row windows   step               (gated on toggle)
            │                 │                  │
       fresh enum;       STALE snapshot     STALE snapshot
       bystander         frame as gate      frame as gate
       (Terminal)        input              input
       clobbered         │                  │
                         └── scrub away → bad frame FROZEN on card
```

`tickLivePreview` is called **ungated** from `gestureDidStep` / `gestureDidStepRow` / `switchSpace`; only the idle timer is gated on the setting. So the "Live preview" toggle leaks — turning it off does **not** stop scrub-time re-capture today.

**Current code reality (verified):** the *only* surviving change from the earlier exploration is `cleanScaleThreshold = 0.85` + the `||` (either-dimension) geometry gate in `ThumbnailService`. Everything else the prior `tasks.md` marked done — a fixed settle (`LiveCaptureSettle`), the proportion gate (`isProportionInconsistent`), the motion gate (`liveFrameSettled` / `liveBounds`), `.fit`, the resolution cap (`captureDimensions`), and live-preview-default-off + its migration — was reverted from code. This change re-scopes only the pieces that belong to the chosen fix.

The Dock-preview feature already solved the capture-timing class with `DockPreviewController.captureDelay = 0.5 s`; the switcher never got an equivalent. All MLX-free Core, so it verifies under `swift build` / `swift test`.

## Goals / Non-Goals

**Goals:**
- A freshly-captured window never shows a transitional / sideways frame — its last good frame holds until it settles, whether the capture comes from the open-time prefetch (bystander) or the live scrub path.
- **Keep live-updating previews.** The highlighted window still refreshes live; the fix removes only the *mid-motion* captures, not the live feature.
- Restore grid render + capture speed to roughly its pre-grid feel without abandoning the real-proportion grid.
- Keep the fix pure/testable: the gate and capture-sizing stay unit-testable; the motion signal is a pure function.

**Non-Goals:**
- Defaulting live preview off / turning the switcher into stable stills (rejected — see below).
- Reverting the real-proportion grid (the feature stays; we fix its *inputs* and revert only `.fill` → `.fit`).
- Any new permission, gesture relocation, re-login, or stream/continuous-capture machinery.
- Changing the Dock preview path beyond what it shares via `ThumbnailService`.

## Decisions

### D1 — Motion gate on the capture, against the window's FRESH frame (primary fix)
Capture a window only when its **current** frame has stopped moving; while the frame is still changing, keep the last good frame.

1. **Fresh gate input.** Stop gating `liveCapture` on the live-session **snapshot** `SCWindow.frame` (taken once at `prepareLiveSession`). Re-read the window's current bounds with a cheap single-id `CGWindowListCopyWindowInfo` (`liveBounds(of:)`) and run `isDegradedCapture` against *that*; fall back to the snapshot only when the live read is unavailable. A window that starts animating *after* the snapshot otherwise passes the gate on its old full-size frame.
2. **Motion signal.** `liveFrameSettled(previous:current:)` — a pure function; capture only when the live frame is **unchanged since the previous observation**. While the window is in flight its frame keeps changing, so the capture is skipped and the card keeps its last good frame for *however long* the animation runs; it resumes the instant the frame holds still. A first observation also defers (one extra tick). A per-session `liveBoundsSeen` map holds the previous frame; cleared in `endLiveSession`.

- *Why this over a fixed settle:* motion is the actual signal — it waits exactly as long as the animation lasts, no more, and is immune to animation-length variation (genie vs scale, the slow-animation accessibility setting, a Dock minimize that outlasts any comfortable fixed delay).
- *Why it also fixes the freeze:* an in-flight window is *never captured*, so scrubbing away leaves the good cached frame intact — there is no transitional frame to freeze on a non-highlighted card.
- *Cost / caveat:* one cheap single-id `CGWindowList` query per live tick. Relies on `CGWindowList` reflecting the animation (bounds change tick-to-tick); if a future macOS reported perfectly static bounds through an animation, D4's `.fit` render and D5's geometry gate remain as backstops.

### D2 — One-shot open prefetch never overwrites a good cached frame (the bystander fix)
The reported repro is a **bystander**: switch VSCode → Telegram, open the switcher, and *Terminal* (never highlighted) goes sideways. Only `prefetch` touches a bystander, and it re-captures *every* cleanly-visible row window on open — clobbering Terminal's good cached frame with a mid-morph capture. Fix: `prefetch` skips any window that **already has a cached frame**; only a never-seen window is captured (still behind the geometry gate). A previously-seen window is served from cache (already seeded) and never re-grabbed at the fragile open-moment.

- *Why this is not "stop re-capturing" (the rejected D7):* this is the **one-shot open** path only. Continuous live refresh of the **highlighted** window stays on (D1) — live previews are preserved. The motion gate has no two-tick signal on a one-shot open capture, so "don't clobber a good frame" is the motion principle's realization there.
- *Residual:* a *never-seen* window that is mid-morph exactly at open can still be captured once; D4's `.fit` makes that frame harmless, and D1 lands a clean frame on the next settled observation. Noted in Open Questions.

### D3 — Make the "Live preview" toggle fully gate continuous re-capture (fix the leak)
Gate the scrub-step `tickLivePreview` (called from `gestureDidStep` / `gestureDidStepRow` / `switchSpace`) on `settings.livePreviewEnabled`, matching the idle timer. With the toggle off, **zero** windows are re-captured during a gesture; the switcher shows stable last-good thumbnails. **The default stays ON** — this only makes the existing toggle mean what it says.

### D4 — Render `.fit` (letterbox), not `.fill` (crop) — the safety net
The grid commit changed the switcher card from `aspectRatio(.fit)` (v0.12 letterbox) to `aspectRatio(.fill)` + crop. `.fill` is what turns an occasional in-flight capture into a glaring sideways *smear*. Revert the switcher card to `.fit`: a GOOD capture (image aspect == the card's real-proportion aspect) still fills the card edge-to-edge, so the Mission-Control look is preserved; only a wrong-aspect transitional frame letterboxes — harmlessly, as in v0.12.

- *Why keep it even with D1/D2:* the capture-side gates reduce how often a bad frame is captured but cannot guarantee zero (a frame can come back at the correct aspect with only tilted *content*, which no geometry/motion test reliably catches). `.fit` makes any survivor inoffensive. The Dock-preview rationale for `.fill` doesn't transfer — the switcher prizes never-sideways over a hairline letterbox gap.

### D5 — Keep the 0.85 geometry gate (already landed)
`cleanScaleThreshold = 0.85` + the `||` (either-dimension) check stays as the backstop for the **small / scaled** phase and the set-aside strip proxy — the part the geometry signal *can* catch. The motion gate (D1) layers on top to catch the bounds-normal / pixels-tilted phase the geometry gate cannot. No change needed; this is the one piece already in the working tree.

### D6 — Bound capture resolution to the display target (perf)
Replace the `1100×700` native-Retina budget with a cap proportional to the on-screen card size × a bounded Retina headroom (≈ 2×) — cards solve to ~180–260 pt, so a cap near `600×400` is ample and ~3–4× cheaper per capture. Extract a pure `captureDimensions(windowSize:backingScale:cap:)` for tests. Shorter capture also shortens any bad frame's time on screen.

### D7 — Lighten the per-frame render (perf)
Drop the card image `.interpolation(.high)` → `.medium`/default: high is the slowest filter, invisible at card scale, and now runs on the smaller D6 bitmap. `.drawingGroup()` on the reel / per-card image scoping is a **measured** follow-up only — do not ship blind.

### Optional hardening — proportion-inconsistency gate
A cheap third degraded signal — the **returned `CGImage`** aspect deviates beyond a tolerance from the window's real-frame aspect — can be added and kept conservative. It catches a mid-transition frame that comes back at a visibly wrong aspect. Optional because D1 + D4 already carry the fix; add only if `TFS_THUMB_LOG` shows wrong-aspect transitional frames the motion gate misses.

## Rejected Alternatives

- **Live preview default OFF / stop continuous re-capture (the old D7 / option A).** Surest at killing the capture, but the user wants live-updating previews kept. The motion gate (D1) achieves no-sideways *without* sacrificing live preview, so default-off is unnecessary. (Its one useful piece — the one-shot prefetch not clobbering a good frame — is retained as D2, scoped to the open moment only.)
- **Fixed settle delay alone (the old D1 / `LiveCaptureSettle`).** A floor, not sufficient: a Dock minimize / slow-animation-accessibility run outlasts any comfortable fixed delay, so the post-settle capture is still in flight. Subsumed by the motion gate, which waits exactly as long as the motion lasts. The motion gate's "first observation defers one tick" is the only settle retained.
- **Rely on a higher threshold alone.** Structurally cannot catch bounds-normal / pixels-tilted (the actual signature). It is kept (D5) only for the phase it *can* catch.

## Risks / Trade-offs

- **Motion gate depends on `CGWindowList` reflecting the animation.** → `.fit` (D4) + geometry gate (D5) are backstops if a frame still slips; validate against `TFS_THUMB_LOG`.
- **One extra `CGWindowList` read per live tick.** → Single-id query, cheap; the prefetch path already re-enumerates.
- **Prefetch don't-clobber can show a slightly stale frame** for a window whose content changed since last cached. → Acceptable for a switcher (recognition over freshness); the highlighted window refreshes live, and Dock cross-population (`inject`) also refreshes the cache.
- **Lower capture resolution → softer thumbnail in the largest cards.** → Derive the cap from real card size × Retina headroom; confirm visually on Retina.
- **`.fit` shows a hairline letterbox** on the rare frame whose capture aspect differs slightly from the AX real frame. → Negligible, and the seed→capture swap doesn't jump (both captures of the same window, same aspect).

## Migration Plan

Pure in-process behavior change — no data migration, no permission, no re-login, **no default flip** (live preview stays on). Ship in one change; rollback is a straight revert. Validate by setting `TFS_THUMB_LOG=1`, reproducing the Stage-Manager app-switch + immediate-open case, and confirming the log shows in-flight frames skipped and steady-state captures landing clean. A rebuild also clears the in-memory thumbnail cache poisoned during testing.

## Open Questions

- A never-seen window that is mid-morph exactly at switcher open is still captured once by `prefetch` (D2 residual); `.fit` makes it harmless and D1 corrects it on the next settled tick. Confirm in-hand this is unnoticeable, or extend D2 to defer a never-seen window's first clean capture to the live-session settle pass.
- Exact resolution cap (D6, start ~600×400) and whether `.drawingGroup()` (D7b) is needed — lock against in-hand measurement.
- Whether the optional proportion gate is needed once D1 + D4 land — decide from `TFS_THUMB_LOG`.
- Keep `TFS_THUMB_LOG` after the fix (it is the validation probe for the motion gate) or remove — currently leaning keep (env-gated, zero cost when unset).
