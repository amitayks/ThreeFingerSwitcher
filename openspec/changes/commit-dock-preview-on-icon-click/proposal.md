## Why

The Dock-preview popup is confusingly inconsistent between its two click targets:

1. **Click a thumbnail card** → the window commits (comes to front and stays).
2. **Click the Dock icon** underneath the popup → the window does **not** stay front.

The second case looks broken. What actually happens: the hovered card has already *peeked* (fronted) its window, and the icon click even lets the native Dock front it again — but because the click never routed through our commit path, the popup treats it as "not a commit." When the cursor then leaves, `dismiss(restore: true)` **re-fronts the window that was frontmost before the peek**, silently undoing the click. So clicking the card sticks (it commits with `restore: false`) while clicking the icon gets reverted on leave.

Users reasonably expect clicking the icon while a live preview is showing to do the same thing as clicking the preview: keep that window front.

## What Changes

- **A left-click on the shown app's own Dock tile commits the highlighted preview.** While the popup is open and a card is highlighted (peeked), a left-click on that app's Dock tile commits the highlighted window via the existing raise path — the same result as clicking the card — so the icon click is no longer undone by the leave-restore.
- **Observed passively, native Dock unaffected.** The left-click is observed by a passive global monitor (the existing `.leftMouseDown` seam, already used by window-groups snap) that **never consumes** the event, so the native Dock still receives the click unmodified — matching the passive contract of the right-click-yields rule.
- **Scoped to the "a card is highlighted" case only.** If no card is highlighted (the cursor never moved onto a thumbnail), the click is left entirely to the native Dock — normal app activation stands, and since nothing was peeked there is no restore to undo. Clicking a *different* app's tile is unchanged (native activation + the usual hover swap).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `dock-hover-detection`: one added requirement — a left-click on the shown app's Dock tile commits the highlighted preview (passively, never consuming the event; only when a card is peeked), the mirror of the existing "right-click yields to the native menu" rule.

## Impact

- **Code:**
  - `Dock/CursorMonitor.swift`: promote the passive `onLeftDown: ((CGPoint) -> Void)?` callback to the `CursorMonitor` seam (add to `ManualCursorMonitor` + an `emitLeftDown` test hook).
  - `Dock/GlobalCursorMonitor.swift`: already installs the passive `.leftMouseDown` monitor for `onLeftDown` — only a doc-comment generalization (a second consumer).
  - `Dock/DockHoverModel.swift`: a pure `leftClick(at:tiles:) -> pid_t?` decision (the active app's pid iff the click hit its tile).
  - `Dock/DockPreviewController.swift`: wire `cursor.onLeftDown` → `handleLeftClick`, which commits `overlay.model.highlightedID` when the click lands on the shown app's tile and a card is highlighted.
- **No new permission** (the passive monitor needs none; reuses already-granted Accessibility/Screen Recording) and **no new dependency**.
- **Tests:** pure-model coverage for the left-click decision. All MLX-free Core → verifies under `swift build` / `swift test`.
