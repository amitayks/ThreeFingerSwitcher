## Why

Live window thumbnails appear only on the first gesture after a window opens; on subsequent gestures the cards show app icon + title only. This regresses the AltTab-style live preview the overlay is meant to provide.

## What Changes

- Cached thumbnails are re-applied to the overlay on **every** showing (the model's thumbnail map is cleared per gesture, so cached images must be re-seeded), and thumbnails are **refreshed** (re-captured) each gesture so they stay live.
- Fix root cause: `ThumbnailService.prefetch` skipped any id already in the cache (`where cache[id] == nil`), so after the first capture it never re-applied the image to the freshly-cleared `SwitcherModel.thumbnails`.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `window-enumeration-and-raising`: the thumbnail behavior now guarantees thumbnails are shown (from cache, immediately) and refreshed on every overlay showing, not just the first.

## Impact

- Code: `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift`, `Sources/ThreeFingerSwitcher/Overlay/SwitcherModel.swift`, `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift`.
- No change to gesture logic, enumeration, raising, permissions, or the cache/placeholder design.
