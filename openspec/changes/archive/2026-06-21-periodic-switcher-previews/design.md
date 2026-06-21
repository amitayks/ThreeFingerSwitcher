## Context

Opening the switcher today runs three things (`AppCoordinator.gestureDidActivate`): `seedAllRows()` (apply every Space's cached frames instantly), `prefetchCurrentRow()` (one-shot capture of the current row's **never-seen, cleanly-presented** windows — cached windows are skipped), and `startLivePreview()` (a 0.1s timer that re-captures **only the highlighted window**, after a 3-tick ~0.3s motion-settle gate).

Two problems, both traced to that design:

1. **It feels laggy.** Freshness rides entirely on the highlight: a card shows a possibly-stale cached frame until you land on it, then the motion-settle gate withholds the first capture for ~0.3s+, so the preview appears ~1s after highlighting — and only updates well for the window the OS is actively rendering (the front app). `de6d52e` ("never capture a sideways thumbnail") is where `prefetch` gained the "skip if already cached" guard and the live path gained the settle gate — i.e. where all freshness moved onto the laggy highlight timer.

2. **Sideways frames still leak.** The motion-settle gate only ever protected the **highlighted** window. Every other card is captured once on open with only the size-based degraded gate, and is **never re-captured** unless highlighted — so a mid-transition ("sideways") frame caught on open is frozen there.

Crucially, none of this is "live" in the video sense: every capture (then and now) is a discrete one-shot `SCScreenshotManager.captureImage` — there is no `SCStream` anywhere. So "live" is a fast screenshot loop on one window, not continuous rendering.

**The hard constraint:** `SCScreenshotManager` returns a window's **last composited** frame, and macOS throttles/suspends rendering for occluded / off-Space / minimized windows. No capture cadence can make an un-rendered window update — fresh pixels exist only for what the OS is currently compositing. Truly fronting a window to force a render is the heavy Dock-preview model (`peekRaise` + SkyLight) and is explicitly out of scope for the switcher.

## Goals / Non-Goals

**Goals:**
- Every visible window shows its last true frame **immediately on open** — no highlight required.
- "Slowly but surely" refresh of the visible row, so changing content updates and any imperfect frame **self-heals** within one sweep instead of being frozen.
- Strictly fewer moving parts than the live model: one mechanism (a slow batch refresh of the visible row) instead of seed + one-shot-prefetch + highlight-timer + motion-settle + live-session.
- Keep the degraded-frame safety gate and the Hub / off-screen exclusions; keep "no new permission, no toggle, silent degrade."

**Non-Goals:**
- Making occluded / off-Space / minimized windows update live (physically requires fronting them — the Dock-preview model, out of scope).
- Any continuous `SCStream` / video preview (never existed; not introducing one).
- A user-facing cadence setting or any live-preview toggle (the prior decision to keep this unconditional stands).
- Per-highlight capture kicks or a "live focus" that follows the selection.

## Decisions

### D1 — One mechanism: a slow batch refresh of the visible row
Replace the highlight-gated live model with a single operation — re-capture **all** of the current Space-row's cleanly-presented windows — run **immediately on open and Space-switch**, then **repeated on a slow timer** while the overlay is open. The highlight stops driving capture entirely; it is purely a selection. *Alternative considered:* keep the live timer but widen it to all windows at 0.1s — rejected as both more expensive and still carrying the motion-settle complexity the lag comes from.

### D2 — Cadence ~0.8s (`previewRefreshInterval`), batch not round-robin
Each sweep re-captures the whole visible row together (~0.8s apart), rather than one-window-per-tick round-robin. The visible row is bounded (typically a handful of cards), `inFlight` already provides per-window back-pressure, and a batch needs no cursor/index state. *Alternative considered:* round-robin for flat per-tick cost — rejected as needless state for a bounded set, and it makes each window's refresh period scale with window count (sluggish on busy Spaces). 0.8s is a tunable constant, not a setting.

### D3 — Capture-on-open + immediate-on-Space-switch
`gestureDidActivate` and `switchSpace` both fire the refresh **synchronously** (the existing `prefetchCurrentRow()` call site), so the newly visible row is captured at once; the timer only handles subsequent sweeps. This is the literal "capture frames the moment the switcher triggers" ask. `seedAllRows()` still runs first so every Space shows cached frames instantly under the fresh capture.

### D4 — Re-capture cleanly-presented windows; keep the degraded skips
Drop the `hasCachedFrame` short-circuit in `prefetch`/`shouldPrefetchCapture` so a window that already has a cached frame **is** re-captured (this is what keeps previews fresh and makes the sweep self-healing). Keep the not-cleanly-presented skips — `isOffAllDisplays` (parked off every display) and `isStripProxy` (Stage-Manager strip), enforced post-capture by `isDegradedCapture` — so an off-screen or strip window is never captured and keeps its last good cached frame. The synthetic Hub card stays excluded as today.

### D5 — Drop the laggy settle machinery; replace with a stateless before/after-capture motion gate
Delete the per-tick settle counter (`liveSettleTicks` / `liveSettleStep` / `liveBoundsSeen`) — that was the lag (it withheld the highlighted window's FIRST capture for 3×0.1s and only ever protected the highlighted card). In its place, gate every capture with **two complementary checks that reject a bad frame before it is stored**, so nothing degraded renders even for one tick:
- **Degraded gate** (`isDegradedCapture`, the 0.85 size + off-display check) on the window's **fresh live frame** — catches a *static*-degraded window (a settled Stage-Manager strip proxy / off-screen set-aside), which a motion check alone would miss.
- **Motion gate** — read the window's live bounds (`liveBounds`, re-added) immediately before and after the screenshot; if they differ, the window was animating (the Stage-Manager tilt / Dock genie only happens *while the frame moves*), so the grabbed pixels are the "sideways" frame → discard. This is the robust signal the earlier releases relied on, but **stateless** (one before/after comparison, `frameMovedDuringCapture`) and **lag-free** (a still window passes instantly — no 3-tick wait, no highlight dependency). The capture duration itself is the motion-detection interval, so it costs only two cheap `CGWindowList` reads.

Together they are strictly more robust than the size gate alone (which let a near-full-size tilted *tail* frame through) while keeping the self-heal sweep as a backstop. *Alternative considered:* the old per-tick cross-sweep settle counter — rejected: it re-adds first-capture latency for the very common static case. *Alternative considered:* inspecting the captured pixels for a tilt — rejected: the image dimensions follow the bounding box, so pixels add no signal the frame geometry/motion don't already give.

### D6 — One `SCShareableContent` enumeration per sweep
Restructure the capture pass so a sweep enumerates `SCShareableContent` **once** and captures every visible window from that single snapshot (today `prefetch` enumerates once per window inside `capture`). Re-enumerating each sweep (≈1.25×/s) keeps frames fresh without the persistent per-gesture live session, so `prepareLiveSession` / `refreshLiveSession` / `endLiveSession` and the `liveWindows` / `liveDisplayUnion` snapshot are all deleted. The per-capture degraded + motion gates (D5) still take their own cheap `liveBounds` reads off this shared enumeration, so each frame is judged on its freshest geometry, not the sweep-start snapshot.

### D7 — Scope = the current Space-row only
The periodic sweep targets only the visible row's windows. Off-Space windows can't be freshly captured anyway (compositing throttle), so re-capturing them every 0.8s is wasted work returning the same frame; they keep their seeded cached frame and refresh when their Space becomes current. `seedAllRows()` still covers all Spaces from cache on open.

### D8 — Teardown is timer invalidation only
`stopPreviewRefresh()` invalidates the timer, idempotently, paired with every overlay teardown site (commit / cancel / touch-engine stop / resign-active / sleep / disable) — the same sites that call `stopLivePreview()` today. There is no live session to tear down, and the cache persists as the last-good-frame store.

## Risks / Trade-offs

- **A "sideways" frame rendering even briefly.** → Mitigation: the before/after-capture motion gate (D5) rejects any frame grabbed while the window's bounds are moving — which is exactly when the tilt happens — so the bad frame is discarded before it is stored, not merely corrected a sweep later. The size gate covers the static-degraded (set-aside strip) case, and self-heal backstops anything that slips both.
- **A window animating very slowly could read as still across the capture and slip the motion gate.** → Mitigation: the Stage-Manager / Dock animations are fast springs whose bounds change every display frame (>16ms), and the before/after reads bracket the whole screenshot, so an in-flight animation reliably shows a delta; the worst residual is one frame that self-heals on the next sweep.
- **Re-capturing the whole visible row every 0.8s is more capture work than the single-window live timer.** → Mitigation: the row is bounded; captures are sized to the card cap (600×400), async, and self-paced by `inFlight`; a single enumeration is shared per sweep. This is the same burst `prefetch` already does on open, just repeated slowly.
- **Off-Space / occluded windows look static.** → By design and unavoidable (D-constraint); they show the last good cached frame, which is correct, just not live. Documented as a Non-Goal.
- **Behavior change is internal** (no API/permission/setting change), so rollback is reverting the change; nothing persisted migrates.

## Open Questions

- Exact cadence (0.7–1.0s) is feel-tunable; starting at **0.8s**. Settle on the value during in-app verification, not in code review.
