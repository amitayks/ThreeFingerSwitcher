## MODIFIED Requirements

### Requirement: Thumbnails shown and refreshed on every overlay showing
The system SHALL display each window's thumbnail every time the overlay is shown — not only the first time — by applying any cached thumbnail immediately on show and refreshing (re-capturing) thumbnails so they stay current across repeated gestures. A refresh SHALL re-capture only windows whose current presentation is *clean* — not minimized, and not set aside under Stage Manager. A set-aside window SHALL be detected as degraded by EITHER signal: (a) its frame is parked off every display (set aside on a non-current Space), OR (b) its displayed (window-server / CGWindowList) frame is a small fraction (below the clean-scale threshold, in EITHER dimension) of its real (Accessibility) frame — a Stage-Manager strip thumbnail or a strip⇄stage transition frame, which sits on-screen at positive coordinates yet renders as a small tilted proxy (the CGWindowList bounds report the scaled rect while Accessibility reports the true size). An off-Space window that is NOT set aside (its displayed frame matches its real size and falls on a display) MAY be re-captured, preserving live off-Space previews; the discriminator for skipping a refresh is the degraded presentation, NOT merely being off the current Space. For a window whose presentation is not clean, the system SHALL keep the existing cached thumbnail (or the app-icon placeholder) and SHALL NOT overwrite a clean cached thumbnail with a degraded capture of the window's current presentation.

The cleanliness signals SHALL be evaluated against the window's **current** frame — a cheap per-window read — NOT a possibly-stale per-gesture snapshot, so a window that began animating after the snapshot is judged on live geometry rather than its old full-size frame. The refresh SHALL ADDITIONALLY skip a window whose current frame is still **changing from tick to tick** (in motion / animating) — keeping its last good frame until the frame holds still — so a window morphing between the Stage-Manager strip and the full stage, or animating to or from the Dock, is never captured in flight even when its bounding geometry momentarily looks full-size.

To prevent re-capturing a window at a moment it may be animating (the in-flight / "sideways" frame), the **one-shot refresh performed when the overlay is shown** SHALL NOT overwrite a window that already has a cached thumbnail: a previously-captured frame is retained and shown, and only a window with **no** cached frame is captured on that showing (still subject to the cleanliness signals). Continuous re-capture of the highlighted window to "stay current" is the **always-on live-preview path** (there is no setting to disable it).

#### Scenario: Cached thumbnail shown on repeat gesture
- **WHEN** the overlay is shown again for a window whose thumbnail was captured on an earlier gesture
- **THEN** the cached thumbnail is applied immediately so the card shows the preview (not icon-only)

#### Scenario: Cleanly-visible window is captured on first sighting, then retained
- **WHEN** the overlay is shown and a cleanly-visible current-Space window has no cached thumbnail yet
- **THEN** its thumbnail is captured so the card shows a preview
- **AND** on a later showing, a window that already has a cached thumbnail is shown from cache and is NOT re-captured by the one-shot refresh (so it cannot be grabbed mid-animation); continuous refresh of the highlighted window happens via the always-on live-preview path

#### Scenario: Set-aside or off-display window keeps its clean cached thumbnail
- **WHEN** the overlay is shown for a window that is set aside under Stage Manager, minimized, or otherwise parked off every display, and a clean thumbnail for it is already cached
- **THEN** the cached thumbnail is shown and the system does NOT overwrite it with a degraded capture of the window's current (tilted/proxy/off-screen) presentation

#### Scenario: Off-Space window still on a display is refreshed
- **WHEN** the overlay is shown for a window on another Space whose frame still falls on a display (not set aside / not off every display)
- **THEN** its thumbnail MAY be re-captured so the off-Space preview stays live, and a clean capture is stored

#### Scenario: Current-Space Stage-Manager strip thumbnail keeps its clean cached thumbnail
- **WHEN** the overlay is shown for a window rendered as a Stage-Manager strip thumbnail on the current Space (on-screen at positive coordinates, but its displayed/CGWindowList frame is a small fraction of its real Accessibility frame in either dimension)
- **THEN** it is treated as degraded: the cached thumbnail (or app icon) is shown and the system does NOT capture or store the small tilted strip bitmap

#### Scenario: Window in motion is not refreshed
- **WHEN** the refresh path targets a window whose current frame is still changing from tick to tick (morphing between the Stage-Manager strip and the stage, animating to or from the Dock, or being resized)
- **THEN** the refresh is skipped while the window is in motion and its last good frame is kept, and a clean capture is taken only once the frame holds still
- **AND** the cleanliness signals are evaluated against the window's current frame, so a window that began animating after the per-gesture snapshot is not captured on its stale full-size frame

#### Scenario: Degraded capture is discarded rather than cached
- **WHEN** a capture would yield a degraded image (the captured frame is detected as a set-aside proxy, a strip/transition frame below the clean-scale threshold, or an off-screen presentation rather than the window's normal content)
- **THEN** the capture result is discarded, the prior cached thumbnail or app-icon placeholder is kept, and no degraded image is stored in the cache

#### Scenario: No duplicate concurrent captures
- **WHEN** a capture for a window id is already in flight
- **THEN** a second capture for the same id is not started

#### Scenario: Fallback unchanged when capture unavailable
- **WHEN** Screen Recording is not granted or a capture fails
- **THEN** the card falls back to the app-icon placeholder
