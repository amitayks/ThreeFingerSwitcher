## ADDED Requirements

### Requirement: Live preview of the highlighted window

While the overlay is open and live preview is enabled, the switcher SHALL continuously re-capture the currently highlighted window and update its card in near-real-time, so a window whose content is changing (video, a scrolling terminal, a running download) is shown live rather than as a single frozen snapshot. At most ONE window SHALL be live-captured at any instant — the highlighted one — and the live focus SHALL follow the selection as it scrubs across the row and between Space-rows.

Live capture SHALL reuse the static thumbnail capture's degraded-frame safety gate (`isOffAllDisplays` / `isStripProxy` / `isDegradedCapture`): a window that is not cleanly presented — parked off every display (Stage-Manager set-aside), a Stage-Manager strip proxy, or the synthetic Hub entry — SHALL NOT be live-captured and SHALL retain its last good static frame, so no live preview ever shows a cropped or sideways image. Live preview SHALL NOT introduce any new permission; when Screen Recording access is absent it SHALL degrade silently to the existing static behavior.

The live layer SHALL be additive over the first-frame bootstrap: opening the overlay still seeds cached static thumbnails and performs the existing one-shot row prefetch, and live re-capture refreshes the highlighted card on top of that. The entire behavior SHALL be gated on the live-preview setting; when the setting is disabled the switcher SHALL behave exactly as the static-only thumbnail strip.

#### Scenario: Highlighted window updates live
- **WHEN** the overlay is open with live preview enabled and the highlighted window's content changes
- **THEN** the highlighted card's thumbnail refreshes to reflect the new content within the capture cadence, without re-creating the strip

#### Scenario: Live focus follows the selection
- **WHEN** the selection scrubs to a different card
- **THEN** the newly highlighted window becomes the live-captured one and the previously highlighted card retains its last captured frame

#### Scenario: At most one window is live
- **WHEN** the overlay is open with live preview enabled
- **THEN** only the currently highlighted window is being re-captured; all other cards hold their last captured (static) frame

#### Scenario: Any cleanly-presented same-Space window can go live
- **WHEN** the highlighted window is any cleanly-presented window on the current Space-row
- **THEN** its live preview reliably begins refreshing while it remains highlighted

#### Scenario: Non-cleanly-presented windows never go live
- **WHEN** the highlighted window is parked off every display, is a Stage-Manager strip proxy, or is the synthetic Hub entry
- **THEN** it is not live-captured and its card keeps its last good static frame (no cropped or sideways image is shown)

#### Scenario: Fast start on highlight change
- **WHEN** the selection moves to a cleanly-presented window
- **THEN** an immediate capture of that window is kicked off (rather than waiting a full cadence interval), reusing a per-gesture cached window lookup so no full content enumeration is on the refresh path

#### Scenario: Disabled restores static-only behavior
- **WHEN** live preview is disabled in settings
- **THEN** the switcher seeds and prefetches thumbnails exactly as before and no continuous re-capture occurs

#### Scenario: Live capture stops on teardown
- **WHEN** the gesture ends by commit, cancel, the touch engine stopping, the app resigning active, system sleep, or the app being disabled
- **THEN** continuous live re-capture stops promptly and idempotently, leaving no capture activity after the overlay is torn down
