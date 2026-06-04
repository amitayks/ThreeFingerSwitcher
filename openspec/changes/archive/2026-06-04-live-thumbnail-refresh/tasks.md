## 1. Fix the thumbnail refresh path

- [x] 1.1 In `ThumbnailService`, add a `seed(into:ids:)` (or equivalent) that applies any cached image to the model immediately for the given ids.
- [x] 1.2 In `ThumbnailService.prefetch`, drop the `cache[id] == nil` guard so cached ids are re-captured (refresh); keep the `!inFlight.contains(id)` guard to avoid duplicate concurrent captures.
- [x] 1.3 In `AppCoordinator.gestureDidActivate`, after `overlay.show(...)`, seed the overlay model's thumbnails from the cache for the snapshot ids, then call `prefetch` to refresh.

## 2. Verify

- [x] 2.1 Build the app and assemble the bundle.
- [ ] 2.2 On-device: confirm thumbnails appear on the first AND subsequent gestures (not icon-only), and update when window content changes.
