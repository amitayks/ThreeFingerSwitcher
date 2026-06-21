## Why

The switcher's "live preview" re-captures only the **highlighted** window on a fast (0.1s) timer, gated behind a 3-tick (~0.3s) motion-settle. In practice it feels laggy — the preview appears ~1s after you land on a window, and only really updates for the frontmost app — and it still lets "sideways" mid-transition frames through on every **other** card, because nothing refreshes a window until you highlight it. The capture primitive was always discrete one-shot screenshots (there is no `SCStream` anywhere), so "live" buys machinery without the responsiveness the word implies. Simpler is better here: we don't need "live" if it isn't working well.

## What Changes

- **BREAKING (internal): Remove the highlight-gated "live preview."** Delete the single-window 0.1s timer, the motion-settle gate, and the per-gesture live session. There is no longer a "one window live at a time / live focus follows the selection" model.
- **Capture every visible window immediately when the switcher opens** (and again immediately when you switch Space), vetted by the existing degraded-frame gate — so you always see each window's last true frame up front, without having to highlight it first.
- **Refresh the visible row on a slow periodic sweep (~0.8s).** Discrete, individually-vetted frames — "slowly but surely" — so changing content (video, a scrolling terminal) updates, and any imperfect frame that slips through self-heals on the next sweep instead of being frozen until you re-highlight.
- **Re-capture cleanly-presented windows on every pass** (drop the "skip if already cached" guard), while still skipping not-cleanly-presented windows (parked off-screen / Stage-Manager strip proxy / the synthetic Hub card) — those keep their last good cached frame.
- No new permission, no toggle; silent degrade to last-good frames when Screen Recording access is absent (unchanged).

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `switcher-overlay`: replace the **"Live preview of the highlighted window"** requirement with a **"Periodic refresh of visible window previews"** requirement — capture-on-open of the whole visible row, a slow all-visible sweep with self-heal, and removal of the single-window live model and its motion-settle gate. The degraded-frame safety gate and the Hub/off-screen exclusions are retained.

## Impact

- **Code:** `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` (the preview timer + its scrub/Space-switch kick sites) and `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift` (remove the live-session + motion-settle machinery; turn the one-shot row prefetch into a batch refresh that re-captures cleanly-presented windows from a single enumeration).
- **Tests:** remove the `liveSettleStep` motion-gate tests and the `shouldPrefetchCapture` "skip cached" cases; keep the `isDegradedCapture` / `isOffAllDisplays` / `isStripProxy` gate tests; add coverage for "re-capture a cleanly-presented cached window" and the periodic sweep.
- **Specs:** `openspec/specs/switcher-overlay/spec.md`.
- **No change** to gesture recognition, grid layout/real-proportion sizing, window raising, Space navigation, the Hub icon-only exclusion, or permissions.
