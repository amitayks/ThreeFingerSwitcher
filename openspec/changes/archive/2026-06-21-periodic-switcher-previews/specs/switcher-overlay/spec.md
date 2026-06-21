## ADDED Requirements

### Requirement: Periodic refresh of visible window previews

While the overlay is open the switcher SHALL keep the **currently visible Space-row's** window previews fresh by re-capturing them as discrete still frames — never a continuous video stream. There SHALL be **no setting or toggle** to disable it, and no "live" single-window mode: capture SHALL NOT be driven by which card is highlighted.

On open (and whenever the visible Space-row changes), the switcher SHALL **immediately** capture every cleanly-presented window in the now-visible row, so each card shows that window's last true frame up front without the user highlighting it. While the overlay remains open, the switcher SHALL **re-capture the visible row on a slow periodic cadence** (the preview-refresh interval, ~0.8s) so that a window whose content is changing (video, a scrolling terminal, a running download) updates over time, and so that any single imperfect frame is overwritten by the next sweep ("self-heal") rather than frozen on the card.

Each refresh SHALL re-capture cleanly-presented windows even when they already have a cached frame (the cached frame is the bridge shown until the fresh capture lands, never a reason to skip the capture). Each capture SHALL be guarded by TWO complementary safety gates so a bad ("sideways") frame is rejected **before it is ever stored or rendered** — not merely corrected on a later sweep:

1. **Degraded-frame gate** (`isOffAllDisplays` / `isStripProxy` / `isDegradedCapture`), evaluated on the window's **fresh live frame**: a window that is not cleanly presented — parked off every display (Stage-Manager set-aside), a Stage-Manager strip proxy, or the synthetic Hub entry — SHALL NOT be captured and SHALL retain its last good cached frame.
2. **Motion gate**: the window's live frame SHALL be read immediately before AND immediately after the capture; if the frame changed across the capture the window was mid-animation (a Stage-Manager perspective morph, a Dock minimize/restore, or an app-switch settle), so the grabbed pixels are the tilted "sideways" frame and the capture SHALL be **discarded** (nothing stored), keeping the last good frame.

A still, cleanly-presented window SHALL pass both gates immediately with no added latency. The periodic sweep remains a backstop ("self-heal"): if any imperfect frame ever slips a gate, a later sweep re-captures the window and replaces it once it is settled.

The refresh SHALL be additive over the cached-frame bootstrap: opening the overlay still seeds every Space's cached static thumbnails first (so all Spaces render instantly and off-row Spaces show their last good frame). The periodic sweep SHALL target only the visible row; off-row Spaces SHALL NOT be periodically re-captured (their windows are not freshly renderable while off-screen) and SHALL refresh when their Space next becomes visible. The refresh SHALL NOT introduce any new permission; when Screen Recording access is absent it SHALL degrade silently to the cached/last-good frames.

#### Scenario: Visible row is captured immediately on open
- **WHEN** the switcher overlay opens
- **THEN** every cleanly-presented window in the visible Space-row is captured at once and its card shows that window's last true frame, without the user highlighting any card

#### Scenario: Visible previews refresh on the slow cadence
- **WHEN** the overlay stays open and a visible window's content changes
- **THEN** that window's card refreshes to the new content within the periodic preview-refresh cadence (no continuous stream, no re-creating the grid)

#### Scenario: A frame grabbed while the window is animating is discarded before it renders
- **WHEN** a window's frame is in motion across the capture — mid Stage-Manager perspective morph, minimizing toward / restoring from the Dock, or settling after an app switch (its live bounds differ immediately before vs. immediately after the capture)
- **THEN** the captured frame is discarded (never stored or rendered) and the card keeps its last good frame, so no tilted "sideways" image appears even for one tick

#### Scenario: A still window is captured with no added latency
- **WHEN** a cleanly-presented window's live bounds are identical immediately before and after the capture (it is settled)
- **THEN** the frame is stored and rendered immediately, with no settle delay

#### Scenario: Self-heal backstops any slipped frame on the next sweep
- **WHEN** a captured frame for a visible window is somehow still imperfect after both gates
- **THEN** the next periodic sweep re-captures that window once it is settled and replaces the frame with a clean one, so the imperfect frame is never frozen on the card

#### Scenario: Refresh is not driven by the highlight
- **WHEN** the overlay is open with several windows in the visible row
- **THEN** all visible cleanly-presented windows are kept fresh by the periodic sweep, not only the highlighted one, and scrubbing the highlight does not itself trigger or gate any capture

#### Scenario: Cleanly-presented cached windows are re-captured
- **WHEN** the periodic sweep runs and a visible cleanly-presented window already has a cached frame
- **THEN** it is re-captured anyway to stay fresh (the cached frame is shown meanwhile), rather than being skipped because it was already cached

#### Scenario: Not-cleanly-presented windows are never captured
- **WHEN** a visible-row window is parked off every display, is a Stage-Manager strip proxy, or is the synthetic Hub entry
- **THEN** it is not captured by the open-time pass nor the periodic sweep, and its card keeps its last good cached frame or icon (no cropped or sideways image is shown)

#### Scenario: Immediate refresh on Space switch
- **WHEN** the visible Space-row changes (a grid-edge vertical scrub switches Space)
- **THEN** the new row's cleanly-presented windows are captured immediately, and the periodic sweep continues against the new row

#### Scenario: Off-row Spaces are seeded but not periodically captured
- **WHEN** the overlay is open
- **THEN** every Space's cards are seeded from cache up front, and only the visible row is periodically re-captured; off-row windows hold their last good cached frame until their Space becomes visible

#### Scenario: No toggle, no new permission
- **WHEN** the user views the Switcher page of the configuration Hub, or Screen Recording access is absent
- **THEN** there is no preview/live toggle and the refresh runs unconditionally whenever the overlay is open; without Screen Recording it degrades silently to cached/last-good frames

#### Scenario: Refresh stops on teardown
- **WHEN** the gesture ends by commit, cancel, the touch engine stopping, the app resigning active, system sleep, or the app being disabled
- **THEN** the periodic refresh stops promptly and idempotently, leaving no capture activity after the overlay is torn down

## REMOVED Requirements

### Requirement: Live preview of the highlighted window

**Reason**: The highlight-gated single-window live model (a 0.1s timer re-capturing only the highlighted window behind a 3-tick motion-settle gate) is laggy — the preview appears ~1s after highlighting and only updates well for the frontmost app — and it never refreshes non-highlighted cards, so sideways frames stay frozen on them. It is replaced by the simpler "Periodic refresh of visible window previews" requirement.

**Migration**: No user-facing or persisted migration. The replacement captures the whole visible row immediately on open and refreshes it on a slow self-healing sweep; the degraded-frame gate, the Hub/off-screen exclusions, the no-toggle/no-new-permission stance, and silent degrade without Screen Recording all carry over unchanged.
