## 1. Shared layout metrics

- [x] 1.1 Extract card metrics (card width, inter-card spacing, outer padding, card internal padding) into a single shared `SwitcherLayout` source of truth.
- [x] 1.2 Update `SwitcherView` to use the shared metrics for card width, spacing, and padding.

## 2. Adaptive panel sizing

- [x] 2.1 In `OverlayController`, compute `contentWidth = outerPadding*2 + N*cardOuterWidth + (N-1)*spacing` from the shared metrics and the snapshot count at `show()` time.
- [x] 2.2 Set `maxWidth = activeScreen.visibleFrame.width - sideMargin`; set `panelWidth = min(contentWidth, maxWidth)`; center the panel horizontally on the active screen.
- [x] 2.3 Ensure the SwitcherView rounded background hugs the panel width so it wraps the cards tightly when not overflowing.
- [x] 2.4 Disable scroll bounce / empty drift when content fits; keep `scrollTo(selectedIndex, anchor: .center)` for the overflow case.

## 3. Verify

- [x] 3.1 Build the app and assemble the bundle.
- [ ] 3.2 On-device: confirm a short list (e.g. 4 windows) hugs-and-centers, and a long list clamps + scrolls with the highlight kept visible.
