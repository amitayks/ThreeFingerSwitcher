## Context

The Dock-preview popup (`dock-window-previews`) is a mouse-interactive, non-activating panel anchored just off a hovered Dock tile. It is anchored in the *gap* between the tile and the popup content precisely so a native click on the Dock icon still falls through to the system Dock. That deliberate design has an unintended side effect:

- Clicking a **card** routes through `overlay.onCommit → commit(id)`, which raises the window and calls `dismiss(restore: false)` — the chosen window stays front.
- Clicking the **icon** never reaches the controller at all. `DockPreviewController` observes cursor moves and right-clicks but has **no left-click handler**. The click falls through to the native Dock (which fronts the app's focused window — the just-peeked one), but the popup is still open (the cursor is on the tile, inside the live zone), so no commit happens.
- When the cursor later leaves the live zone, `dismiss(restore: true)` fires. Because a peek fronted a window (`peekedID != nil`), it calls `peekRaise(restoreTarget)` — **restoring the window that was frontmost before the peek**, undoing the icon click.

So the card click sticks and the icon click is silently reverted. The fix makes an icon click on the shown app's tile route through the same commit path as a card click.

Relevant constraints: all of this is MLX-free Core (verifies under `swift build`/`swift test`); the panel stays non-activating and never key/main; teardown stays synchronous (Space-switch ghost landmine); no new permission, no new dependency; the passive-monitor "observe, don't intercept" contract established by the right-click-yields rule.

## Goals / Non-Goals

**Goals:**
- A left-click on the shown app's Dock tile, while a card is highlighted, commits that highlighted window — the same result as clicking the card.
- The native Dock still receives the click unmodified (passive observation, never consumed).
- Keep the new logic unit-testable (a pure left-click decision), consistent with the codebase's seam-based testing and the mirror right-click decision.

**Non-Goals:**
- Committing anything when **no** card is highlighted — the native Dock activation is left to stand (nothing was peeked, so nothing is restored/undone). No "pick the frontmost window for the user" magic.
- Consuming the Dock click to *prevent* the native activation. That would require a heavy `CGEventTap` (rejected by the feature's passive / no-new-permission contract) and risk breaking normal Dock use.
- Any change to the peek/capture pipeline, the overlay panel's level/style, the switcher, or the card-click commit path.

## Decisions

### D1 — Observe the left-click with the existing passive monitor; decide in the pure model
`GlobalCursorMonitor` already installs a passive global + local `.leftMouseDown` monitor surfaced as `onLeftDown` (built for window-groups snap). A global `NSEvent` monitor **cannot consume** another app's event, so the native Dock still gets the click — the same "observe, don't intercept" property the right-click rule relies on. Promote `onLeftDown` from a concrete-only property to the `CursorMonitor` seam (the Dock controller holds the protocol type), so no new monitor is installed. The decision lives in a pure `DockHoverModel.leftClick(at:tiles:) -> pid_t?` — it returns the **active** app's pid iff the click hit-tests onto *that* app's tile, else nil. Keeping it pure mirrors `rightClick(at:tiles:)` and keeps it testable without AppKit.

*Alternatives considered:* a new dedicated `.leftMouseDown` monitor (redundant — one already exists); adding a `.commit` case to the `Decision` enum (pollutes the enum that `feed()` returns; `leftClick`'s natural answer is "which app's tile got the click," a `pid_t?`); deciding entirely in the controller (loses the pure-model test seam).

### D2 — Commit only the *highlighted* window, and only on the *shown* app's tile
The controller commits `overlay.model.highlightedID` when (a) the popup is visible, (b) the pure model says the click landed on the active app's tile, and (c) a card is actually highlighted. The highlighted card is the peeked (live) window, so committing it matches exactly what the user is looking at — and what the native Dock would front anyway, since the peek already made it the app's focused window. `commit(id)` reuses the card-click path: `raiseDeminimizing` (un-minimizes a minimized card first) then `dismiss(restore: false)`, so the leave-restore no longer undoes it. A stale/gone highlighted id is caught by `commit`'s existing `currentWindows` guard.

Restricting to the **shown app's own tile** means clicking a *different* app's tile is untouched — that click activates the other app natively and, via the live-zone model, swaps the popup to it, which is the existing (correct) behavior. When **no** card is highlighted, `handleLeftClick` no-ops: the native activation stands, and because nothing was peeked (`peekedID == nil`) the eventual dismiss doesn't restore anything, so there is nothing to undo.

### D3 — Accept that the native Dock also acts (we cannot consume the click)
Unlike a card click (consumed by our overlay so the native Dock never sees it), an icon click fires the native Dock activation **in addition** to our commit — the passive monitor can't stop it. For a **live** highlighted window the two converge: the peek already made it the app's focused window, so native activation fronts the same window we commit. For a **minimized** highlighted window, native activation won't reliably de-minimize *that specific* window, but our `raiseDeminimizing` does — so at worst there's a brief two-window surface. Consuming the click to avoid this is explicitly out (D-Non-Goals). This is the one behavior to confirm on the real signed build (pure-model + build/test can't exercise live AX).

## Risks / Trade-offs

- **Native-Dock double-action** (D3) → for a live window, benign (both target the peeked/focused window); for a minimized window, a small risk of an extra window surfacing. Validate in the real app.
- **Grazed-then-clicked-icon** → if the cursor grazed a card on the way to the icon, `highlightedID` is that grazed window and the icon click commits it. This is intended: the graze already peeked (fronted + focused) it, so native activation would front it regardless; committing just makes it stick instead of being reverted.
- **Left-mouse-down that begins a drag** (e.g. rearranging a Dock icon) also fires `onLeftDown`; worst case we commit the highlighted window, which native would front anyway. Rare and harmless; not worth distinguishing down-vs-click.
