## Context

The three-finger switcher serves the *trackpad-flow* moment. This change adds a parallel, *mouse-flow* affordance: hover a Dock app tile, get a row of that app's windows on the current Space, peek any one live, click to bring it forward. It is opt-in (default off) and adds **no new permission** — it reuses the already-granted Accessibility (read the Dock's AX tree, raise windows) and Screen Recording (ScreenCaptureKit thumbnails).

The codebase already owns ~80% of the machinery:
- `WindowService.snapshot()` enumerates windows with owner pid, frame, AX element, and an `isOnCurrentSpace` tag.
- `ThumbnailService` captures cached row thumbnails and `liveCapture(window, logicalFrame)` per-frame live content for the switcher's highlighted card.
- `WindowService.raise()` is a hardened raise path (AX `kAXRaiseAction` + SkyLight + activation + watchdog + Stage-Manager hold-guard).
- `SwitcherPanel` (non-activating `NSPanel`) is the overlay substrate.

The two genuinely new pieces are (1) **Dock-hover detection** — the app has never touched the Dock or tracked the cursor continuously — and (2) a **mouse-interactive overlay**, the app's first cursor-first surface (every existing overlay sets `ignoresMouseEvents = true`).

Constraints from CLAUDE.md: keep logic in MLX-free `ThreeFingerSwitcherCore` (pure, injectable seams; AppKit/AX/capture glue at the app boundary, mirroring the Files/Player seams); overlay teardown stays **synchronous** (the ghost-on-Space-switch landmine); errors map to a Core `LocalizedError` taxonomy surfaced as bounded, non-blocking cards — never `NSAlert`, never raw error text in a headline.

## Goals / Non-Goals

**Goals:**
- Hover a Dock app tile → a row of that app's **current-Space** windows (normal **and minimized**) appears, anchored to the tile.
- Hover a tab → the **real window is fronted** so it shows its true live content at its actual position/size; leaving without a click **restores** the previously-front window.
- Click a tab → that window is raised permanently (de-minimizing first if needed); a peek otherwise leaves the desktop as it was.
- Adapt to Dock orientation (bottom/left/right), the Dock's display, auto-hide reveal, and magnification.
- Skip apps with no windows on the current Space (no empty popup).
- Stay opt-in, default off, no new permission, no gesture relocation, no re-login.

**Non-Goals:**
- No custom/replacement Dock. We overlay the real Dock; we never hide or reimplement it.
- No cross-Space windows in the row (current Space only, by design).
- No window operations beyond raise (no close/minimize/move/quit from the popup) in v1.
- No keyboard navigation of the popup (it is cursor-driven; the trackpad switcher remains the keyboard/gesture path).
- No previews for Dock items that aren't running apps (folders/stacks, Trash, minimized-window tiles to the right of the separator, Downloads).

## Decisions

### D1 — Overlay on the real Dock via Accessibility; do NOT build a Dock
`Dock.app` is closed with no plugin surface and no "icon hovered" event. But its AX tree is readable: `AXUIElementCreateApplication(dockPid)` → the tiles list → per-tile `kAXPosition`/`kAXSize` (which update live under magnification), `kAXTitle`, and a resolvable app identity (`kAXURL`/title → bundle id → running pid). We float a panel **above** the Dock and infer hover ourselves. Building our own Dock would mean reimplementing running indicators, badges, bounce, drag-reorder, stacks, Trash, minimized tiles, right-click menus, persistence, and multi-monitor behavior — enormous and fragile, for zero benefit to this feature. **Prior art** (HyperDock, DockView) proves the AX-overlay approach is viable. *Rejected: custom Dock.*

### D2 — Peek = front the real window and restore it (revised)
*Initially* the peek projected the window's content into the popup card via `ThumbnailService.liveCapture`, leaving the real window untouched. Testing surfaced a hard macOS constraint that invalidates that approach for a *true* live preview: **macOS does not render fresh pixels for a window that is not on screen**, so an occluded (or minimized) window captures as a stale/last frame or just its icon — exactly what the first build showed. The only way to a genuine, updating, full-size preview is to bring the **real window to the front** so the system renders it live at its true position and size.

So the peek now: (1) records the previously-frontmost window at peek-session start (`WindowService.frontmostWindow()`); (2) on hover, **front-raises** the hovered window with a lightweight, reversible `WindowService.peekRaise` (no focus-history promotion, no watchdog, no Stage-Manager hold-guard — those fight a quick put-back); (3) on leave **without commit**, restores the recorded window. A **click** commits via the hardened `raiseDeminimizing` and skips restore. **Minimized** windows are not fronted to peek (that needs de-minimizing) — they surface only on commit. The **tabs** keep the switcher's cache-first / last-good-frame safety so they never show a sideways proxy, and a peeked (fronted) window yields a clean tab frame that persists. **Accepted trade-off:** this is the Windows Aero-Peek model and macOS has no perfectly clean "put back," so rapid hovering can cause some z-order/focus churn — bounded by only raising on hover-enter (not per tick) and by the current-Space-only scope (the cheap AX raise path). *Reversed from the original "never raise / project-only" decision.*

### D3 — Cursor tracking: edge-gated, then hot
The app currently reads `NSEvent.mouseLocation` only at snapshot time. Detection needs a continuous-ish read, but a global high-rate poll is wasteful. Strategy: a **passive global `.mouseMoved` monitor** (no new permission — observing mouse-moved does not require Input Monitoring) that does cheap work until the cursor enters the Dock's strip region (derived from the AX tile-frame union / screen edge + orientation), then switches to **hot mode**: re-read tile frames from AX and hit-test at interactive rate so magnified tiles are tracked accurately. Leaving the strip (and the popup) returns to idle. The poll/monitor only runs while the feature is enabled. *Alternative considered: a `CGEventTap` for mouse-moved — heavier and unnecessary since we only observe; the passive monitor suffices.*

### D4 — Dock geometry is read, not assumed
Orientation (bottom/left/right), the Dock's display, and tile frames all come from AX (with `com.apple.dock` `orientation`/`autohide` defaults as a hint). The popup anchors to the hovered tile's frame on the correct screen with orientation-aware placement (above for bottom Dock, beside for left/right). **Magnification:** tile frames are re-queried while hot, so the anchor follows the growing tile. **Auto-hide:** the strip is off-screen until revealed; detection is a two-step chain (cursor reaches the edge → Dock reveals → tiles become hit-testable), handled by re-reading AX after reveal rather than caching stale frames.

### D5 — A mouse-interactive panel: the app's first cursor-first surface
Every existing overlay sets `ignoresMouseEvents = true`. This popup is the opposite — it must receive hover and click on its thumbnails. It reuses `SwitcherPanel` but **accepts mouse events** and is **non-activating** (does not steal app focus / key status; closest to the AI canvas's `keyInteractive` exception, but here it stays click-receiving without becoming the app's focus). The native Dock click on the icon itself is **not** intercepted — the popup is positioned in the gap between the tile and the desktop content, so clicking the icon still does the system thing; our commit is a click on a *thumbnail*, not the icon. Teardown stays **synchronous** (`orderOut`), honoring the ghost-on-Space-switch landmine.

### D6 — A new enumeration variant: app-scoped, current-Space, minimized-inclusive
The switcher's enumeration is all-Spaces and **excludes** minimized windows — unchanged. The popup needs the opposite slice: one app, current Space only, **including** minimized windows. This is an additive enumeration mode on `WindowService` (filter by owner pid + `isOnCurrentSpace`, and stop dropping the minimized subrole when this mode asks for them), not a change to the switcher's contract. Minimized windows are flagged so the row can badge them and the commit path knows to de-minimize.

### D7 — Commit reuses `raise()`, plus un-minimize
Clicking a normal window's thumbnail calls the existing `raise()`. Clicking a **minimized** window's thumbnail first un-minimizes it (AX `kAXMinimizedAttribute = false`) and then raises it. All of `raise()`'s hardening (watchdog, Stage-Manager hold-guard, activation fallback) is inherited.

### D8 — Hover/leave/dismiss lifecycle with hysteresis
The model is a small pure state machine (idle → tileHovered(pid, anchor) → previewOpen → committed/dismissed). To avoid flicker when the cursor travels from the tile up into the popup, the popup region and the tile region are treated as one "live zone": leaving the tile toward the popup keeps it open; leaving the whole live zone after a short grace period dismisses it (and the in-flight `liveCapture` session ends). Moving to a different tile swaps the contents. A re-list keeps stable thumbnail identity (window id) so the row doesn't strobe.

### D9 — Core/app boundary mirrors the Files/Player seams
Pure, synchronous, testable in Core:
- `DockHoverModel` — the lifecycle state machine + hit-testing math (given tile frames + cursor → hovered pid/anchor), orientation-aware anchor computation.
- `DockPreviewModel` — the row model (windows, highlight, minimized flags), peek selection.
Injected at the app boundary (`main.swift`), framework-touching:
- a `DockReader` seam (AX read of tiles → `[DockTile{pid, frame, title}]`),
- a `CursorMonitor` seam (passive global mouse-moved → cursor point),
- reuse of `ThumbnailService`/`WindowService` for capture/enumerate/raise/un-minimize.
This keeps Core MLX-free and `swift build`/`swift test`-verifiable; the AX/cursor glue degrades to no-op (never crash) if a private path is unavailable.

### D10 — Opt-in, default off; coexists with the native Dock
A single `showDockPreviews` flag in `AppSettings`, surfaced on the Configuration Hub, gates the whole subsystem (the cursor monitor isn't even installed when off). Default off. It takes effect immediately (no re-login, no `isEffective` gate), like the Files band. The native Dock behavior is untouched whether on or off.

## Risks / Trade-offs

- **Dock AX brittleness across macOS versions** → Keep the `DockReader` a thin, isolated seam with defensive attribute reads; degrade to no popup (never crash) if the tile list/attributes can't be read. Cover the hit-test/anchor math with Core unit tests so behavior is verifiable independent of the live AX tree.
- **Magnification jitter** (anchor chasing a moving tile) → Re-query while hot and anchor to the tile's *current* frame; if jitter is distracting, anchor to the tile's settled/base frame instead. Tunable, feel-only.
- **Auto-hide reveal chain** → Re-read AX after reveal rather than caching; treat "Dock hidden" as idle until the reveal animation exposes hit-testable tiles.
- **Occluded windows render stale** (peek may not update for self-throttling apps) → Accepted; same limitation as the switcher's live highlight. Live capture is still the actual backing store, which is fresh for the vast majority of apps.
- **Multi-monitor / Dock on a non-primary display** → Use AX global coords + the Dock's reported display; anchor on that screen. Test bottom and side orientations.
- **Cursor-interactive panel stealing focus** → Keep it non-activating; never set it key/main as the app's focus target; verify the previously focused window is still the raise target on commit (the switcher-overlay invariant).
- **Performance of continuous tracking** → Edge-gated: idle work is negligible; hot work only while the cursor is in the Dock strip / popup. Monitor only installed when the feature is enabled.
- **Interaction with `.accessory` activation policy** (the app has no Dock tile of its own) → Fine; we read *other* apps' tiles, and never need our own.
- **Native Dock click vs. our commit** → Popup sits in the gap above the tile; thumbnail clicks commit, icon clicks fall through to the system. Verify no overlap region eats icon clicks.

## Open Questions

- Anchor to the *magnified* (live) tile frame or the *base* tile frame? Start with live; revisit if jitter is distracting.
- Reveal trigger for an auto-hidden Dock — only after the system reveals it, or proactively? Start reactive (no proactive reveal).
- Should the popup also offer commit-on-mouse-up vs. a distinct click? Start with a plain click on the thumbnail; peek is hover.
