## MODIFIED Requirements

### Requirement: Live preview of the highlighted window

Live preview SHALL remain **ON by default**: while the overlay is open the switcher SHALL continuously re-capture the currently highlighted window and update its card in near-real-time, so a window whose content is changing (video, a scrolling terminal, a running download) is shown live rather than as a single frozen snapshot. At most ONE window SHALL be live-captured at any instant — the highlighted one — and the live focus SHALL follow the selection as it scrubs across the row and between Space-rows.

The live-preview setting SHALL fully gate **all** continuous re-capture — including the eager re-capture kicked on each scrub step, not only the idle timer — so when the setting is off, **no** window is re-captured during a gesture and the switcher shows stable last-good thumbnails. (No default flip and no migration: the default stays on; the setting only gains the property that off means off.)

Live capture SHALL reuse the static thumbnail capture's degraded-frame safety gate (`isOffAllDisplays` / `isStripProxy` / `isDegradedCapture`): a window that is not cleanly presented — parked off every display (Stage-Manager set-aside), a Stage-Manager strip proxy, or the synthetic Hub entry — SHALL NOT be live-captured and SHALL retain its last good static frame. The cleanliness signals SHALL be evaluated against the window's **current** frame (a cheap per-window read), NOT a possibly-stale per-gesture snapshot, so a window that began animating after the snapshot is not captured on its stale full-size frame. Furthermore, while the highlighted window is **in motion** — its current frame still changing tick-to-tick, e.g. morphing between the Stage-Manager strip and the full stage, or animating to or from the Dock — it SHALL NOT be live-captured at all; its last good frame SHALL be retained until the frame holds still, so an in-flight ("sideways") frame is neither shown nor frozen onto its card by scrubbing away before it settles. Live preview SHALL NOT introduce any new permission; when Screen Recording access is absent it SHALL degrade silently to the existing static behavior.

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

#### Scenario: Non-cleanly-presented windows never go live
- **WHEN** the highlighted window is parked off every display, is a Stage-Manager strip proxy, or is the synthetic Hub entry
- **THEN** it is not live-captured and its card keeps its last good static frame (no cropped or sideways image is shown)

#### Scenario: Cleanliness is judged on the window's current frame
- **WHEN** the highlighted window began animating (e.g. toward the Dock) AFTER the per-gesture capture snapshot was taken
- **THEN** the degraded-frame gate is evaluated against the window's current (fresh) frame, not the stale snapshot, so the in-flight window is recognized as not-clean and is not captured on its old full-size geometry

#### Scenario: Window in motion is not captured in flight
- **WHEN** the highlighted window is mid-animation — morphing between the Stage-Manager strip and the full stage, or minimizing toward / restoring from the Dock — so its current frame is still changing from tick to tick
- **THEN** it is not live-captured while in motion and its card keeps its last good frame, for as long as the animation runs
- **AND** scrubbing to another window before it settles does not leave an in-flight ("sideways") frame frozen on its card
- **AND** once the window stops moving, the next tick captures a clean frame

#### Scenario: Toggle off stops all scrub-time re-capture
- **WHEN** live preview is disabled in settings and the user opens the switcher and scrubs across windows
- **THEN** no window is re-captured during the gesture — neither by the idle timer nor on each scrub step — and each card shows its last good thumbnail
- **AND** the switcher otherwise seeds and prefetches thumbnails exactly as before

#### Scenario: Live capture stops on teardown
- **WHEN** the gesture ends by commit, cancel, the touch engine stopping, the app resigning active, system sleep, or the app being disabled
- **THEN** continuous live re-capture stops promptly and idempotently, leaving no capture activity after the overlay is torn down

## ADDED Requirements

### Requirement: Real-proportion grid renders within the live cadence

The real-proportion card grid SHALL render the highlighted window's live updates smoothly at the capture cadence. Card images SHALL be drawn from **display-bounded** bitmaps (sized to what the card shows — see the capture-sizing requirement in window-enumeration-and-raising — rather than the window's full native resolution), and the per-card image resampling cost SHALL be kept proportional to the displayed card size. A card SHALL scale its thumbnail to **fit** (letterbox) within its real-proportion bounds rather than cropping/zooming it to fill, so a capture whose aspect does not match the card — a transitional / in-flight frame that slipped past the capture-side gates — is shown harmlessly reduced rather than smeared into a sideways image; a clean capture (whose aspect matches the card) fills the card edge-to-edge.

#### Scenario: Card image is drawn from a display-bounded bitmap
- **WHEN** a card renders a window's thumbnail
- **THEN** the underlying bitmap it resamples is bounded to roughly the displayed card size (times a Retina headroom), so resampling a large source window does not cost more than the card displays

#### Scenario: A good capture fills its proportioned card without distortion
- **WHEN** a clean, settled capture is shown in its card
- **THEN** it fills the card (which is sized to the window's real proportion) edge-to-edge with no sideways or stretched appearance

#### Scenario: A mismatched-aspect capture letterboxes rather than cropping sideways
- **WHEN** a card's available thumbnail has an aspect ratio that does not match the card's real-proportion bounds (a transitional / in-flight frame that slipped past the capture-side gates)
- **THEN** it is scaled to fit (letterboxed) within the card, not cropped or zoomed to fill — so no sideways or stretched image is ever shown
