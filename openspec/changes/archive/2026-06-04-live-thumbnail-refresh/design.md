## Context

`SwitcherModel.setWindows` clears `thumbnails = [:]` on each gesture (the snapshot is new). `ThumbnailService` keeps an LRU cache keyed by `CGWindowID`, but `prefetch` only captured ids where `cache[id] == nil`. So after the first gesture caches the images, later gestures clear the model, then `prefetch` skips all cached ids and never re-applies them → icon-only cards.

## Goals / Non-Goals

**Goals:**
- Thumbnails show on every gesture (immediately from cache, then refreshed).
- Keep the placeholder-then-fill design (D7) and the icon fallback when capture is unavailable.

**Non-Goals:**
- Continuous capture during a single gesture (refresh granularity is per-activation).
- Any change to enumeration, raising, or gesture logic.

## Decisions

### D1 — Seed from cache on show, then always re-capture
On overlay show, apply any cached image for the snapshot ids to the model immediately (instant display, possibly slightly stale). Then `prefetch` re-captures all visible ids to refresh. The cached image bridges the async capture so there is no icon-only flash on repeat showings.

### D2 — `prefetch` refreshes instead of skipping cached ids
Drop the `cache[id] == nil` guard so cached ids are re-captured (keeping them live); keep the `!inFlight.contains(id)` guard so we never launch duplicate concurrent captures for the same id. `capture()` continues to update both the cache and the model via `onThumbnail`.

## Risks / Trade-offs

- **[Slightly more capture work per gesture]** → Mitigation: captures are async and capped to the visible cards; the cached image shows instantly so latency is hidden.
- **[Stale image shown briefly before refresh]** → Acceptable: the seed is immediate and the refresh replaces it within the same gesture.
