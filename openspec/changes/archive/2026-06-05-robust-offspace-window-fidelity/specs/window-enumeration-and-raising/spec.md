## MODIFIED Requirements

### Requirement: Off-Space windows are enumerated
The system SHALL include normal windows that are not on the current Space — windows on other desktop Spaces, native-fullscreen Spaces, and windows (or Spaces) that existed before the app launched — using the private CoreGraphicsServices per-Space enumeration. Listing an off-Space window SHALL require an Accessibility element for that window, obtained either (a) live via remote-token brute force, or (b) from a persistent cache populated while the window was reachable on the current Space (on its application's activation, or a prior snapshot) — a cached element stays valid across Spaces. The system SHALL NOT list an off-Space window from CoreGraphicsServices/CGWindowList metadata alone: a window for which no Accessibility element resolves on any Space is treated as not a real, switchable window — a closed-but-process-alive window, a dialog/sheet that exposes no Accessibility window, or a background-agent surface — and SHALL be excluded, even when its metadata (non-zero alpha, normal layer, real-sized frame) resembles a real window. To keep genuine off-Space windows listed — including windows a remote-token brute force cannot reach (historically Chromium-based; reachability is build-dependent) — the persistent element cache SHALL be seeded whenever a window is reachable on the current Space (at minimum on its application's activation and on every snapshot's current-Space pass), so a window observed once on the current Space remains listable after it moves off-Space. As before, a resolved element (live or cached) SHALL still pass the standard-window switchability test (standard window subrole, not minimized) to be listed. Minimized windows SHALL remain excluded, and the set and order of current-Space windows SHALL be unchanged from before this change.

#### Scenario: Window on another desktop Space is listed
- **WHEN** a normal window exists on a desktop Space other than the current one AND an Accessibility element for it resolves live or from cache
- **THEN** it appears in the switcher list

#### Scenario: Native-fullscreen window is listed
- **WHEN** an app is in native fullscreen (its own Space) and its window has a resolvable or cached Accessibility element
- **THEN** its window appears in the switcher list

#### Scenario: Off-Space window reachable only via a cached element is still listed
- **WHEN** a normal off-Space window's owning app exposes no Accessibility element reachable by remote-token brute force (historically a Chromium-based browser, though reachability is build-dependent — on the captured Tahoe build Chrome was reachable) but an element was cached while the window was previously reachable on the current Space
- **THEN** the window is still listed using the cached element (the "Bug A" raise path), rather than being dropped

#### Scenario: Off-Space window with no Accessibility element anywhere is excluded
- **WHEN** an off-Space window has no Accessibility element resolvable by remote-token brute force AND none cached (it is absent from its app's Accessibility tree on every Space — e.g. a closed-but-process-alive window, a dialog/sheet that exposes no Accessibility window, or a background-agent surface such as a screen-share overlay)
- **THEN** it is NOT listed, so it never appears as a stale "ghost" card — even though its CoreGraphicsServices metadata (non-zero alpha, normal layer, real-sized frame) looks like a real window

#### Scenario: Shadow and companion windows still excluded
- **WHEN** the per-Space enumeration surfaces an invisible companion or shadow window (zero alpha, degenerate frame, or non-normal layer) that has no Accessibility element
- **THEN** it is excluded (no Accessibility element → not listed), so it does not appear as a duplicate in the switcher list

#### Scenario: Window created before launch is listed when reachable
- **WHEN** a window or fullscreen Space was created before the app started AND an Accessibility element for it resolves live or from cache
- **THEN** it appears in the switcher list

#### Scenario: Minimized still excluded; current Space unchanged
- **WHEN** the list is built
- **THEN** minimized windows are excluded and the set/order of current-Space windows is unchanged from before this change

### Requirement: Thumbnails shown and refreshed on every overlay showing
The system SHALL display each window's thumbnail every time the overlay is shown — not only the first time — by applying any cached thumbnail immediately on show and refreshing (re-capturing) thumbnails so they stay current across repeated gestures. A refresh SHALL re-capture only windows whose current presentation is *clean* — not minimized, and not set aside under Stage Manager. A set-aside window SHALL be detected as degraded by EITHER signal: (a) its frame is parked off every display (set aside on a non-current Space), OR (b) its displayed (window-server / CGWindowList) frame is a small fraction of its real (Accessibility) frame — a Stage-Manager strip thumbnail on the current Space, which sits on-screen at positive coordinates yet renders as a small tilted proxy (the CGWindowList bounds report the scaled strip rect while Accessibility reports the true size). An off-Space window that is NOT set aside (its displayed frame matches its real size and falls on a display) MAY be re-captured, preserving live off-Space previews; the discriminator for skipping a refresh is the degraded presentation, NOT merely being off the current Space. For a window whose presentation is not clean, the system SHALL keep the existing cached thumbnail (or the app-icon placeholder) and SHALL NOT overwrite a clean cached thumbnail with a degraded capture of the window's current presentation (e.g. a Stage-Manager set-aside strip proxy or an off-screen frame).

#### Scenario: Cached thumbnail shown on repeat gesture
- **WHEN** the overlay is shown again for a window whose thumbnail was captured on an earlier gesture
- **THEN** the cached thumbnail is applied immediately so the card shows the preview (not icon-only)

#### Scenario: Cleanly-visible window is refreshed to stay live
- **WHEN** the overlay is shown and a window is cleanly visible on the current Space
- **THEN** its thumbnail is re-captured so the preview reflects current window content

#### Scenario: Set-aside or off-display window keeps its clean cached thumbnail
- **WHEN** the overlay is shown for a window that is set aside under Stage Manager, minimized, or otherwise parked off every display, and a clean thumbnail for it is already cached
- **THEN** the cached thumbnail is shown and the system does NOT overwrite it with a degraded capture of the window's current (tilted/proxy/off-screen) presentation

#### Scenario: Off-Space window still on a display is refreshed
- **WHEN** the overlay is shown for a window on another Space whose frame still falls on a display (not set aside / not off every display)
- **THEN** its thumbnail MAY be re-captured so the off-Space preview stays live, and a clean capture is stored

#### Scenario: Current-Space Stage-Manager strip thumbnail keeps its clean cached thumbnail
- **WHEN** the overlay is shown for a window rendered as a Stage-Manager strip thumbnail on the current Space (on-screen at positive coordinates, but its displayed/CGWindowList frame is a small fraction of its real Accessibility frame)
- **THEN** it is treated as degraded: the cached thumbnail (or app icon) is shown and the system does NOT capture or store the small tilted strip bitmap

#### Scenario: Degraded capture is discarded rather than cached
- **WHEN** a live capture would yield a degraded image (the captured frame is detected as a set-aside proxy or off-screen presentation rather than the window's normal content)
- **THEN** the capture result is discarded, the prior cached thumbnail or app-icon placeholder is kept, and no degraded image is stored in the cache

#### Scenario: No duplicate concurrent captures
- **WHEN** a capture for a window id is already in flight
- **THEN** a second capture for the same id is not started

#### Scenario: Fallback unchanged when capture unavailable
- **WHEN** Screen Recording is not granted or a capture fails
- **THEN** the card falls back to the app-icon placeholder

### Requirement: Raise an off-Space window with a single Space switch
The system SHALL raise and key-focus a chosen off-Space window, causing exactly one Space switch, and only at commit (never during scrubbing). Current-Space windows SHALL continue to raise without any Space switch. The Space switch is driven by `kAXRaiseAction` on the window's Accessibility element. For a window whose element a fresh remote-token brute force cannot resolve (e.g. a Chromium window), the system SHALL raise it via an element captured in the persistent cache while the window was reachable; a cached element stays valid across Spaces and `kAXRaiseAction` on it performs the Space switch. The system SHALL NOT attempt a direct Space switch via private CoreGraphicsServices Space APIs — those are gated to the window server's privileged Dock connection and are inert for an unentitled process. Because off-Space listing now requires a live-or-cached Accessibility element (see "Off-Space windows are enumerated"), a window with no element is never listed and therefore cannot be committed; should a listed window's element nonetheless go stale between snapshot and commit, the raise SHALL re-resolve it (live or cached) and, failing that, degrade to fronting the owning application (an off-Space window may still cross Spaces via the SkyLight front/key handshake on its window id; a current-Space window switches no Space) without crashing.

#### Scenario: Commit to off-Space window switches once and focuses
- **WHEN** the user commits to a window on another Space that has a (live or cached) Accessibility element
- **THEN** the system switches to that Space exactly once and the window becomes frontmost with keyboard focus

#### Scenario: No-AX off-Space window navigates via its cached element
- **WHEN** the committed off-Space window exposes no Accessibility element reachable by remote-token brute force, but its element was cached earlier (its app was activated or it was enumerated on a visible Space)
- **THEN** `kAXRaiseAction` on the cached element switches to the window's Space and gives it keyboard focus

#### Scenario: Window with no Accessibility element is not committable
- **WHEN** an off-Space window has no live and no cached Accessibility element (e.g. a Chromium window off-Space since before launch and never focused)
- **THEN** it is not listed (per the off-Space enumeration requirement) and so the user cannot commit to it — the former front-the-app fallback behavior remains only as a defensive (no-crash) guarantee for a listed window whose element goes stale at commit

#### Scenario: Current-Space commit does not switch Spaces
- **WHEN** the user commits to a window on the current Space
- **THEN** the window is raised and focused with no Space switch

#### Scenario: Window closed mid-gesture
- **WHEN** the committed window no longer exists (or its Accessibility element no longer resolves) at commit time
- **THEN** the raise re-resolves what it can and otherwise degrades to a no-op / best-effort app front, and the app does not crash

## ADDED Requirements

### Requirement: Diagnostics expose off-Space listing and thumbnail fidelity
The `--diag` diagnostic report SHALL expose enough state to choose the off-Space listing and thumbnail discriminators from observed data rather than assumption. The report SHALL include a per-candidate dump of every layer-0 window owned by a regular app — including windows that are dropped — recording, for each: owner, name, bounds, alpha, on-screen flag, whether a live (brute-force or current-Space) Accessibility element resolved, whether a cached element exists, and the resulting listing decision. (CoreGraphicsServices Space membership was dumped during investigation but proved inert on this OS — it returns the same count for every window — so it is not a required field.) This dump SHALL make the ghost discriminator observable — that a ghost (closed-but-process-alive window, dialog/sheet, or background-agent surface) has no Accessibility element on any Space (live and cached both absent) while every genuine window has at least one. The thumbnail path SHALL be able to record the ScreenCaptureKit-reported window frame alongside the window's logical frame so the set-aside/off-screen signal can be confirmed.

#### Scenario: Per-candidate listing decision is dumped
- **WHEN** the diagnostic report is generated
- **THEN** for each layer-0 regular-app window it records the CoreGraphicsServices attributes, whether a live and/or cached Accessibility element resolved, and the listing decision, so that ghosts (no Accessibility element anywhere) are distinguishable from genuine off-Space windows

#### Scenario: Thumbnail frame comparison is observable
- **WHEN** a thumbnail capture runs with frame logging enabled
- **THEN** the ScreenCaptureKit-reported frame and the window's logical frame are recorded so a degraded (set-aside/off-screen) capture can be distinguished from a clean one
