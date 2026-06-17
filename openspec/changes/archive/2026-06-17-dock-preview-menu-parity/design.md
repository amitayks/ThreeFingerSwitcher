## Context

The Dock-preview popup (`dock-window-previews`) is a mouse-interactive, non-activating panel anchored just off a hovered Dock tile. When the user invokes a tile's native action menu it diverges from the Dock's own behavior:

- **Z-order on right-click.** `DockPreviewController` runs a `0.12s` hover tick while the popup is open. On a tick where the cursor is still over the shown app's tile, it calls `reanchor(pid)` → `overlay.show(at:)` → `panel.orderFrontRegardless()`. So when the native Dock menu opens on a right-click, the next tick (≤120ms) re-fronts our panel above it.
- **Re-appear behind the menu.** Even after dismissing on the right-click, the global `.mouseMoved` monitor is still live; the next cursor move (cursor still over the tile) re-triggers the hover and re-opens the popup behind the open menu.

A second, separately-investigated goal — keeping an **auto-hidden Dock visible** under the popup, the way the native menu holds it — was found **infeasible** from outside the Dock (see "Rejected" below); the landed behavior degrades gracefully.

Relevant constraints: all of this is MLX-free Core (verifies under `swift build`/`swift test`); the panel must stay non-activating and never key/main; teardown must stay synchronous (Space-switch ghost landmine).

## Goals / Non-Goals

**Goals:**
- A right-click on a Dock tile dismisses the preview so the native menu is unobstructed and always in front.
- The preview does not re-appear behind the menu on a stray cursor move while the menu is up.
- Keep the new logic unit-testable (a pure right-click decision), consistent with the codebase's seam-based testing.

**Non-Goals:**
- Rendering the popup *behind* the native menu (keep-both-visible). Rejected — see D2.
- Keeping an auto-hidden Dock visible under the popup. Investigated and found infeasible — see "Rejected" below.
- Any change to the peek/commit/capture pipeline, the overlay panel's level/style, or the switcher. New permissions or dependencies.

## Decisions

### D1 — Detect the right-click with a passive global monitor; decide in the pure model
Add a passive `.rightMouseDown` monitor alongside the existing cursor monitor (`GlobalCursorMonitor` already runs global + local `.mouseMoved`/`.leftMouseDragged`). A global `NSEvent` monitor **cannot consume** another app's event, so the native Dock menu opens unmodified — "observe, don't intercept." The monitor surfaces an `onRightClick(point:)` callback on the `CursorMonitor` seam. The decision lives in the pure `DockHoverModel.rightClick(at:tiles:) -> Decision` — `.dismiss` iff the point hit-tests onto a tile (any on-tile right-click, whether or not a popup is currently shown, so it can also suppress a not-yet-open popup), else `.idle`.

*Alternatives considered:* a local-only monitor (misses clicks delivered to Dock.app — must be global); deciding inside the controller (loses testability).

### D2 — Dismiss on right-click, rather than render the popup behind the menu
Tearing the popup down is deterministic and **window-level-independent**: it does not depend on the (unknown, cross-process) window level of the Dock's contextual menu. The alternative — lower our level / stop re-fronting so the menu renders above a still-visible popup — is fragile and visually messy (menu and popup stack over the same tile). Dismiss matches intent: a right-click means "I want the menu."

### D3 — Suppress re-opening for the right-clicked tile until the cursor leaves it
Dismissing alone isn't enough: the live global `.mouseMoved` monitor re-triggers the hover on the very next move (cursor still on the tile) and re-opens the popup behind the menu. So the controller records the right-clicked tile (`menuSuppressedPID`); while the cursor remains over that tile, `handleCursor` short-circuits (no hover-model feed, no re-show). It clears the instant the cursor leaves the tile, so normal hover resumes immediately (and moving to another app opens its preview as usual).

*Why "cursor left the tile" as the signal:* there is no reliable, cheap way to observe the Dock's menu *closing* from outside the Dock. "Cursor still on the tile" covers the reported bug (a tiny move right after the right-click) and the common dismissal paths (selecting an item / clicking away both move the cursor off the tile). *Known edge:* dismissing the menu with **Escape without moving the mouse** leaves the popup suppressed until the cursor next leaves the tile — acceptable; the alternative (AX-polling the Dock for an open menu) is more complexity for a rare path.

### D4 — Drop `orderFrontRegardless()` from the reanchor path
`reanchor` should only reposition the (already-visible) panel — `setFrame(_:display:)` does not change z-order. Split the overlay into `show(at:)` (positions + front-orders, for open/swap) and `move(to:)` (reposition only, for the per-tick reanchor). This is correct on its own (re-fronting 8×/sec is wasteful and stomps other apps' transient windows) and is a second line of defense behind D2/D3.

## Rejected: keeping the auto-hidden Dock visible (infeasible)

The original second goal was to hold an auto-hide Dock revealed under the popup, like the native menu does. Every avenue was tried and ruled out — recorded here so it isn't re-litigated:

- **Disable auto-hide via `CoreDockSetAutoHideEnabled(false)`** (implemented, then reverted): does NOT "hold the peek" — it makes the Dock a permanent, space-**reserving** element, so AppKit shrinks `visibleFrame` and **reflows/shrinks every window**. User-rejected.
- **Simulate cursor presence** — post synthetic `.mouseMoved` to Dock.app at an in-Dock point (`CGEvent.postToPid`): the Dock **polls the real HID cursor**, so posted events are ignored. Confirmed not working in the real app.
- **Mimic the right-click menu's hold without the menu:** the menu's "stay revealed" is the Dock's internal **modal-menu-tracking** state — no standalone API, and inseparable from the menu actually painting (menus open on mouse-down).
- **Private CoreDock surface:** enumerated all ~80 `CoreDock*` symbols (HIServices). The *only* auto-hide controls are `Get/SetAutoHideEnabled` (the reflow toggle). No "suspend/hold auto-hide" exists. `CoreDockSetDragStatus` (disassembled) is a 3-arg drag-protocol call needing a drag-context pointer + an undocumented Mach message — a deep RE hole with high crash risk and unknown payoff.

**Verdict:** only the Dock can hold its own peek. **Landed behavior:** when an auto-hide Dock slides away, the popup **freezes in place and stays usable** (no reflow, no crash). Only affects users who auto-hide their Dock.

## Risks / Trade-offs

- **Re-open latency after the menu closes** (D2/D3) → cosmetic; resolved by any cursor movement off the tile.
- **Motionless-Escape edge** (D3) → preview stays suppressed until the cursor leaves the tile; rare, self-resolving.
- **Auto-hide users see the Dock slide away** when moving onto the popup → graceful (popup stays usable); unavoidable per "Rejected" above.
