## 1. Left-click detection on the seam (D1)

- [x] 1.1 Promote `onLeftDown: ((CGPoint) -> Void)?` to the `CursorMonitor` protocol (passive left-mouse-down report; the `.leftMouseDown` global monitor can't consume the event → native Dock click unaffected). `GlobalCursorMonitor` already implements it — generalize its doc comment (a second consumer alongside window-groups snap).
- [x] 1.2 `ManualCursorMonitor`: add the `onLeftDown` property (protocol conformance) + an `emitLeftDown(_:)` test hook mirroring `emitRightClick`.

## 2. Pure decision (D1, D2)

- [x] 2.1 Add `DockHoverModel.leftClick(at:tiles:) -> pid_t?` — returns the **active** app's pid iff the click hit-tests onto that app's tile, else nil (off-tile, other tile, popup, desktop).

## 3. Commit on icon click (D2, D3)

- [x] 3.1 Wire `cursor.onLeftDown` (set/cleared in `setEnabled`): `handleLeftClick(point)` guards `enabled` + `overlay.isVisible`, reads tiles, and when `hover.leftClick(at:tiles:)` is non-nil AND `overlay.model.highlightedID` is set, calls `commit(highlightedID)` (reuses the card-click path → `raiseDeminimizing` + `dismiss(restore: false)`).

## 4. Tests (MLX-free Core)

- [x] 4.1 `DockHoverModel.leftClick(at:tiles:)`: commit-pid over the active app's own tile; nil over another app's tile, over the popup / empty space, and when nothing is active. (4 tests, green.)

## 5. Verify

- [x] 5.1 `swift build` green; `swift test` green (1724 tests, 0 failures). All new code is MLX-free Core.
- [x] 5.2 `CLAUDE.md` Dock-previews section updated: left-click on the shown app's tile commits the highlighted preview (mirror of right-click-yields), passive/never-consumed, highlighted-only.
- [ ] 5.3 Real-app confirmation (user): hover a Dock icon → hover a window preview → click the **icon** → that window stays front (no leave-restore undo); with no card highlighted, the icon click just activates the app natively.
