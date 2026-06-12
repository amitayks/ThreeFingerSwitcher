## Context

Today the switcher captures each window once, when the gesture starts:
`AppCoordinator.prefetchCurrentRow()` → `ThumbnailService.seed()` (instant cached frames) → `ThumbnailService.prefetch()` → one `SCScreenshotManager.captureImage()` per window → `cache` + `onThumbnail` → `SwitcherModel.thumbnails[id]` → `SwitcherView` card. A degraded-frame gate (`isOffAllDisplays` / `isStripProxy` / `isDegradedCapture`) prevents a set-aside / Stage-Manager-strip / off-screen window from overwriting a good cached frame, so the strip never shows cropped or sideways images.

We want the *highlighted* card to refresh continuously so changing content reads as live, while keeping every one of those safety properties and not paying for N concurrent capture pipelines. The chosen approach (from the explore session) is **timer-driven re-snapshot of the selected window only** — not `SCStream`. The switcher is ephemeral (open ~1–2 s while the gesture is held), so a few frames per second on one window is plenty and lets us reuse the entire existing capture + safety + rendering path.

Constraints that shape the design:
- The expensive part of `capture()` is the async `SCShareableContent.excludingDesktopWindows(...)` enumeration, run today on every call. At a live cadence that would dominate latency and waste work.
- Frames flow through `@Published thumbnails[id]`; that is fine for one card at a few fps, but would thrash SwiftUI if applied to every card at high fps. Scoping live to one card keeps it cheap.
- A live capture pipeline must die at every overlay teardown site or it becomes an invisible power/thermal leak.

## Goals / Non-Goals

**Goals:**
- The highlighted card refreshes in near-real-time; the live focus follows the selection across cards and Space-rows.
- Exactly one window is live-captured at a time.
- Any cleanly-presented current-Space window reliably goes live when highlighted; non-cleanly-presented windows (set-aside / strip proxy / Hub) never go live and keep their last good static frame — zero new cropped/sideways failure modes.
- Live starts as fast as possible after a highlight change (immediate kick + per-gesture cached window lookup, no enumeration on the hot path).
- A persisted Hub toggle gates the whole behavior; off == today's static-only strip.

**Non-Goals:**
- No `SCStream` / continuous GPU capture; no layer-backed live view; no per-frame `SCStreamFrameInfo` handling.
- No more than one window live at a time (no "all cards live").
- No change to the wizard demo strip (keeps its static/sample thumbnails), the Hub synthetic entry (icon-only), or off-Space static previews.
- No new permission and no new dependency.

## Decisions

### D1: Timer-driven re-snapshot of the selected window (Road A), not SCStream
Reuse `SCScreenshotManager.captureImage` on a repeating cadence for the highlighted window only. Rationale: reuses the existing capture, cache, `onThumbnail`, `inFlight`, and the entire degraded-capture safety gate verbatim; smallest, lowest-risk diff; the overlay's ~1–2 s lifetime makes 30 fps streaming wasted polish. *Alternative considered:* `SCStream` per window — smooth but needs a new layer-backed render path, teardown discipline for N pipelines, and per-frame status handling; rejected as disproportionate for an ephemeral overlay. Promoting just the selected card to a real stream later remains possible without disturbing this design.

### D2: Hoist `SCShareableContent` to once-per-gesture; live frame is a bare `captureImage`
`ThumbnailService` gains a live session: `prepareLiveSession()` performs one `SCShareableContent.excludingDesktopWindows(...)` and stores a `[CGWindowID: SCWindow]` map; `liveCapture(id:)` looks the window up in that map and calls `captureImage(filter, config)` directly. Rationale: this is what makes live "start as fast as we can" — the only async enumeration happens once, not per frame. The map is fixed to the overlay's window snapshot (which is itself fixed at open), so it stays correct for the overlay's lifetime; refreshed on row change as a safety/coverage measure. *Fallback for reliability:* if a highlighted id is missing from the map (rare), fall back to the existing enumeration-based `capture()` so coverage is never lost. The slightly-stale `SCWindow.frame` only affects output scaling, not which content is captured (the filter captures current content), so staleness is harmless for a 1–2 s overlay.

### D3: Same safety gate, applied per live frame
`liveCapture(id:)` runs the identical `isOffAllDisplays` / `isStripProxy` / `isDegradedCapture` checks before storing/emitting. A window that fails the gate is skipped (its last good frame stays), exactly as the static path does. The synthetic Hub entry is excluded the same way `prefetchCurrentRow()` already excludes it. Rationale: the user's dock/sideways-safety requirement is satisfied for free — live is just the static path run repeatedly through the same gate.

### D4: Cadence self-paces via the existing `inFlight` guard
The `AppCoordinator` live timer fires at a short interval (≈100 ms target), but each tick captures only if no capture for that id is `inFlight`. Rationale: if a capture round-trip is slower than the interval, ticks are skipped and the effective rate equals actual capture throughput — literally "as fast as we can" with no overrun or queue buildup. The interval is a single named constant, easy to tune.

### D5: Each tick targets "whatever is highlighted now"; highlight change kicks an immediate capture
The timer reads `overlay.model.selectedWindow` fresh each tick, so the live target follows the selection with no explicit retarget bookkeeping. Additionally, `gestureDidStep` / `gestureDidStepRow` trigger one immediate `liveCapture` of the newly highlighted window so live appears within a frame of hovering rather than waiting up to one interval. Rationale: combines correctness (timer is the steady state) with snappiness (immediate kick on hover).

### D6: Lifecycle owned by `AppCoordinator`, tied to the overlay's exact lifetime
Start the timer and `prepareLiveSession()` in `gestureDidActivate` (only when the setting is enabled). Stop the timer and `endLiveSession()` idempotently at every teardown site: `gestureDidCommit`, `gestureDidCancel`, `disable`, `handleWillSleep`, resign-active, and touch-engine stop. Rationale: the spec already mandates "panel is always torn down" at these sites; live capture hangs off the same hook so it cannot outlive the overlay. A `stopLivePreview()` that is safe to call when already stopped guarantees no leak.

### D7: Persisted `AppSettings.livePreviewEnabled`, default ON, surfaced on the Switcher page
Add the boolean following the established `AppSettings` pattern (Keys / Defaults / init / didSet-persist) and a `ToggleRow`/`Toggle` on the Switcher page of `HubFeaturePages`. Default **ON**, included in `resetToDefaults`. Rationale: the feature's purpose is to make the switcher feel live by default; it adds no new permission (static thumbnails already require Screen Recording) and is power-trivial (one window, self-paced, ephemeral). "An option to toggle" is read as the ability to turn it *off*. Toggling off mid-overlay stops live capture via a settings observer; toggling on while the overlay is visible starts it. *Alternative considered:* default OFF (opt-in) to match clipboard/AI opt-ins — rejected because those gate a new permission or new subsystem, whereas this refines an always-on existing behavior; the value is in being the default experience. Flipping the default is a one-line change if the power posture changes.

## Risks / Trade-offs

- **[SwiftUI churn from per-tick `@Published` writes]** → Only one card updates per tick at a self-paced few fps; the strip is not re-created (highlight/scroll already update without rebuild). If profiling shows churn, the single live card can later move to a layer-backed `NSViewRepresentable` without touching the rest of the design.
- **[Live timer leaks → invisible power/thermal cost]** → `stopLivePreview()`/`endLiveSession()` are idempotent and wired into every teardown site (D6); the timer also no-ops when `overlay.isVisible` is false. The single-window scope caps worst-case cost even if a stop were missed for one frame.
- **[Stale cached `SCWindow` if a window moves/resizes during the overlay]** → Only affects output scaling, not captured content; refreshed on row change; acceptable for a 1–2 s overlay. Enumeration-based fallback (D2) covers a missing id.
- **[Screen Recording permission absent]** → `liveCapture` is gated on `CGPreflightScreenCaptureAccess()` exactly like `prefetch`; live degrades silently to static, same as today — no new failure surface.
- **[Off-Space / set-aside windows when scrubbing to another row]** → The safety gate (D3) keeps them on their last good frame; genuinely-live updates only occur for current-Space, cleanly-presented windows, which is the intended scope and matches "same-Space" semantics.
- **[Re-capturing the just-focused window every interval when content is static]** → Harmless (same frame re-stored); `inFlight` back-pressure and single-window scope keep cost negligible; not worth dirty-region detection for an ephemeral overlay.
