## Why

The switcher overlay is currently a fixed, near-full-screen-wide panel with cards left-aligned, so a short list (e.g. four windows) bunches the cards on the left with a large empty gap to the right. It should feel centered and tight when the list is short, while keeping the scroll-to-reveal behavior when there are more cards than fit.

## What Changes

- **Adaptive container width**: when the cards fit within the available screen width, the overlay container shrinks to wrap the cards exactly and is centered horizontally on the active screen (no scrolling, no empty space).
- **Overflow unchanged**: when the cards are wider than the available width, the container clamps to the max width, stays centered, and scrolls to keep the highlighted card visible (existing behavior preserved).
- Card layout metrics become a single shared source of truth so the panel width can be computed consistently with how the cards lay out.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `switcher-overlay`: add a requirement that the overlay container width adapts to the card count — hug-and-center when content fits, clamp-and-scroll when it overflows.

## Impact

- Code: `Sources/ThreeFingerSwitcher/Overlay/OverlayController.swift`, `Sources/ThreeFingerSwitcher/Overlay/SwitcherView.swift`.
- No change to gesture logic, window enumeration, or raising.
- No new dependencies or permissions.
