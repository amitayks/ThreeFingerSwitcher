## 1. Right-click detection (D1)

- [x] 1.1 Extend the `CursorMonitor` seam with `onRightClick: ((CGPoint) -> Void)?` (+ `ManualCursorMonitor.emitRightClick`).
- [x] 1.2 `GlobalCursorMonitor`: passive global **and** local `.rightMouseDown` monitor reporting `NSEvent.mouseLocation`; torn down in `stop()` and `deinit`. Global monitors can't consume the event → native Dock menu opens unmodified.
- [x] 1.3 Pure `DockHoverModel.rightClick(at:tiles:) -> Decision` — `.dismiss` for any on-tile right-click (whether or not a popup is shown), `.idle` off all tiles.

## 2. Dismiss + suppress (D2, D3)

- [x] 2.1 Wire `cursor.onRightClick` (set/cleared in `setEnabled`): `handleRightClick` feeds `hover.rightClick(at:tiles:)`; on `.dismiss`, dismiss any open popup (`restore: true` puts back a peeked window).
- [x] 2.2 Record the right-clicked tile (`menuSuppressedPID`); in `handleCursor`, while the cursor is still over that tile, short-circuit (no hover-model feed, no re-show); clear it the moment the cursor leaves the tile. Also cleared in `dismiss`.

## 3. Reanchor never re-fronts (D4)

- [x] 3.1 Add `overlay.move(to:)` (reposition only) and switch `reanchor` to it; `openApp` still front-orders via `overlay.show(at:)`.

## 4. Tests (MLX-free Core)

- [x] 4.1 `DockHoverModel.rightClick(at:tiles:)`: dismiss over a tile (incl. another app's tile while open, and when nothing is open → suppress); no-op off all tiles. (4 tests, green.)

## 5. Verify

- [x] 5.1 `swift build` green; `swift test` green (872 tests). All new code is MLX-free Core.
- [x] 5.2 `CLAUDE.md` Dock-previews section updated: right-click yields + suppress-while-menu-up + reanchor reposition-only; plus a landmine recording that keeping an auto-hide Dock visible is infeasible (don't retry).
- [x] 5.3 Real-app confirmed (user): right-click a tile while the popup is up → native menu in front, and the popup stays gone (doesn't re-appear behind the menu) as the cursor moves on the icon.

## 6. Rejected (recorded, not implemented)

- [x] 6.1 Keeping an auto-hidden Dock visible under the popup — investigated exhaustively (auto-hide toggle reflows windows; Dock polls the real cursor so synthetic events are ignored; no private "suspend auto-hide" API; the menu's hold is inseparable from the visible menu). Concluded infeasible; the dead `DockRevealKeeper`/`DockAutoHide` experiment was removed. Landed behavior: graceful native-hide (popup freezes in place + stays usable). See `design.md` → "Rejected".
