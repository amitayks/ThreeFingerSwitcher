## Why

When the Dock-preview popup is up, it doesn't yield to the Dock's own native menu:

1. **Right-click loses to the popup.** Right-clicking a Dock tile opens the system action menu *behind* the preview popup — because the controller's 0.12s hover tick calls `orderFrontRegardless()` on every reanchor, yanking our panel back on top of the just-opened menu.
2. **The popup re-appears behind the menu.** Even after dismissing on right-click, the next cursor move (cursor still over the tile) re-triggers the hover and re-shows the popup behind the open menu.

The menu should always win and stay unobstructed.

(A second goal — keeping an **auto-hidden Dock visible** under the popup, like the native menu does — was investigated thoroughly and found **infeasible** from outside the Dock. See "What Changes" and `design.md`. The landed behavior degrades gracefully.)

## What Changes

- **Right-click on a Dock tile yields to the native menu.** A passive global right-mouse monitor detects a right-click; if it lands on a Dock app tile, the popup tears down (restoring any peeked window) so the system menu owns the stage. The right-click itself is never consumed — the native Dock menu opens unmodified.
- **Suppress re-opening while the menu is up.** After a right-click on a tile, the preview is suppressed for that tile while the cursor remains over it, so a stray move doesn't pop it back up behind the menu. Normal hover resumes the moment the cursor leaves the tile.
- **Stop the gratuitous per-tick re-fronting.** Reanchor only repositions the panel; it no longer re-orders the panel to the front every tick (front-ordering happens on open/swap only). Hygiene that also removes the mechanism behind issue 1.
- **Investigated and rejected — keeping an auto-hidden Dock visible under the popup.** No mechanism works from a third-party app: disabling auto-hide makes the Dock reserve space and **reflows/shrinks windows**; the Dock polls the **real HID cursor**, so synthetic events are ignored; the full CoreDock private surface has **no "suspend auto-hide"** primitive (the only auto-hide control is the reflow toggle); and the native menu's hold is **modal-menu-tracking** state, inseparable from the visible menu. Landed behavior: when an auto-hide Dock slides away the popup **freezes in place and stays usable** (graceful, no reflow). Only affects users who auto-hide their Dock; an always-visible Dock is unaffected.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `dock-hover-detection`: one requirement — a right-click on a Dock tile dismisses the preview, yields to the native menu (passively, never consuming the event; never re-fronting over it), and suppresses re-opening for that tile while the menu is up.

## Impact

- **Code:**
  - `Dock/CursorMonitor.swift` + `Dock/GlobalCursorMonitor.swift`: a passive global/local `.rightMouseDown` monitor surfaced as an `onRightClick(point:)` callback.
  - `Dock/DockHoverModel.swift`: a pure `rightClick(at:tiles:)` decision (dismiss/suppress iff the click is over a tile).
  - `Dock/DockPreviewController.swift`: wire right-click → dismiss; suppress re-opening via `menuSuppressedPID` (cleared when the cursor leaves the tile); drop `orderFrontRegardless()` from the reanchor path.
  - `Dock/Overlay/DockPreviewOverlay.swift`: split `show(at:)` (front-orders) from `move(to:)` (reposition only).
- **No new permission** (passive monitors need none; reuses already-granted Accessibility/Screen Recording) and **no new dependency**.
- **Tests:** pure-model coverage for the right-click decision. All MLX-free Core → verifies under `swift build` / `swift test`.
