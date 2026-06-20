## MODIFIED Requirements

### Requirement: Live preview of the highlighted window

Live preview SHALL be **always on**: while the overlay is open the switcher SHALL continuously re-capture the currently highlighted window and update its card in near-real-time, so a window whose content is changing (video, a scrolling terminal, a running download) is shown live rather than as a single frozen snapshot. There SHALL be **no setting or toggle** to disable it. At most ONE window SHALL be live-captured at any instant — the highlighted one — and the live focus SHALL follow the selection as it scrubs across the row and between Space-rows.

Live capture SHALL reuse the static thumbnail capture's degraded-frame safety gate (`isOffAllDisplays` / `isStripProxy` / `isDegradedCapture`): a window that is not cleanly presented — parked off every display (Stage-Manager set-aside), a Stage-Manager strip proxy, or the synthetic Hub entry — SHALL NOT be live-captured and SHALL retain its last good static frame. The cleanliness signals SHALL be evaluated against the window's **current** frame (a cheap per-window read), NOT a possibly-stale per-gesture snapshot, so a window that began animating after the snapshot is not captured on its stale full-size frame. Furthermore, while the highlighted window is **in motion** — its current frame still changing tick-to-tick, e.g. morphing between the Stage-Manager strip and the full stage, or animating to or from the Dock — it SHALL NOT be live-captured at all; its last good frame SHALL be retained until the frame holds still, so an in-flight ("sideways") frame is neither shown nor frozen onto its card by scrubbing away before it settles. Live preview SHALL NOT introduce any new permission; when Screen Recording access is absent it SHALL degrade silently to the existing static behavior.

The live layer SHALL be additive over the first-frame bootstrap: opening the overlay still seeds cached static thumbnails and performs the existing one-shot row prefetch, and live re-capture refreshes the highlighted card on top of that.

#### Scenario: Highlighted window updates live
- **WHEN** the overlay is open and the highlighted window's content changes
- **THEN** the highlighted card's thumbnail refreshes to reflect the new content within the capture cadence, without re-creating the strip

#### Scenario: Live focus follows the selection
- **WHEN** the selection scrubs to a different card
- **THEN** the newly highlighted window becomes the live-captured one and the previously highlighted card retains its last captured frame

#### Scenario: At most one window is live
- **WHEN** the overlay is open
- **THEN** only the currently highlighted window is being re-captured; all other cards hold their last captured (static) frame

#### Scenario: No toggle to disable live preview
- **WHEN** the user views the Switcher page of the configuration Hub
- **THEN** there is no live-preview toggle, and live preview runs unconditionally whenever the overlay is open

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

#### Scenario: Live capture stops on teardown
- **WHEN** the gesture ends by commit, cancel, the touch engine stopping, the app resigning active, system sleep, or the app being disabled
- **THEN** continuous live re-capture stops promptly and idempotently, leaving no capture activity after the overlay is torn down
