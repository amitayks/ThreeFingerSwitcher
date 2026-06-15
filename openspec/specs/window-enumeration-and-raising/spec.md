# window-enumeration-and-raising Specification

## Purpose

Define enumeration of normal windows across all Spaces in MRU order, thumbnail capture via ScreenCaptureKit, and raising+focusing a chosen window using the Accessibility API and application activation.
## Requirements
### Requirement: Enumerate normal windows across all Spaces
The system SHALL enumerate normal application windows across all Spaces, excluding minimized windows by default, and SHALL snapshot this ordered list at the start of each gesture.

#### Scenario: Includes windows on other Spaces
- **WHEN** the window list is built
- **THEN** normal windows on Spaces other than the current one are included

#### Scenario: Excludes minimized windows
- **WHEN** a window is minimized
- **THEN** it is not included in the switcher list

#### Scenario: Snapshot is frozen during gesture
- **WHEN** a gesture begins
- **THEN** the ordered window list is captured once and not re-ordered while scrubbing

### Requirement: MRU ordering with z-order fallback
The system SHALL order the window list by **per-window** most-recently-focused recency, fully interleaved across applications, so a short flick lands on the previously focused window regardless of which app owns it. Windows of the same application SHALL NOT be clustered ahead of a more-recently-focused window of another application. The currently focused (frontmost) window SHALL be ordered first and the previously focused window second. Windows with no recorded focus history (never focused since launch) SHALL fall back to the existing ordering — current-Space windows first, then Mission Control Space order, then on-screen z-order. Recency SHALL be tracked per `CGWindowID` and held in memory only (it resets on relaunch); recency ordering applies *within* a Space-row and SHALL NOT reorder the Space-rows themselves.

#### Scenario: Previous window is adjacent across apps
- **WHEN** the user alternates between a window of app A and a window of app B while an untouched second window of app A is also open
- **THEN** a single step from the current window reaches the previously focused window (the app-B window), not the untouched second app-A window

#### Scenario: Same-app windows are not clustered
- **WHEN** the snapshot is built and the most-recently-focused windows belong to different applications
- **THEN** windows are ordered by per-window focus recency, interleaving applications, rather than grouped so that all windows of one application precede windows of another

#### Scenario: Current window first, previous window second
- **WHEN** the overlay is shown
- **THEN** the currently focused window is ordered first and the window focused immediately before it is ordered second

#### Scenario: Fallback to z-order for never-focused windows
- **WHEN** no focus history exists for some windows
- **THEN** those windows are ordered after all windows that do have history, by current-Space-first then Mission Control Space order then on-screen stacking order

#### Scenario: Recency is ephemeral
- **WHEN** the app relaunches
- **THEN** no focus recency is carried over and ordering falls back to the z-order/Space heuristics until windows are focused again

### Requirement: Thumbnail capture via ScreenCaptureKit
The system SHALL capture per-window thumbnails using ScreenCaptureKit and SHALL degrade to an app-icon placeholder when a thumbnail is unavailable or Screen Recording permission is not granted.

#### Scenario: Thumbnail rendered when permitted
- **WHEN** Screen Recording permission is granted and a window is on the list
- **THEN** a thumbnail image is captured and provided to the overlay

#### Scenario: Placeholder when capture unavailable
- **WHEN** a thumbnail cannot be captured for a window
- **THEN** the app icon is used as a placeholder

### Requirement: Raise and focus the chosen window
The system SHALL raise and focus a chosen window using the Accessibility API and application activation, bringing it forward and giving it keyboard focus.

#### Scenario: Commit raises and focuses
- **WHEN** a window is committed
- **THEN** it is raised (kAXRaiseAction), set as main/focused, and its application is activated so it has keyboard focus

#### Scenario: Cross-Space commit switches once
- **WHEN** the committed window is on another Space
- **THEN** the Space switch occurs exactly once at commit time, not during scrubbing

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

### Requirement: Crash-safe degradation when private Space APIs are unavailable
The system SHALL resolve all private Space/raise symbols at startup and, if any required symbol is missing, SHALL fall back to current-Space-only enumeration and raising — never crashing at launch and never regressing below the prior behavior.

#### Scenario: Missing private symbol degrades, not crashes
- **WHEN** a required private symbol cannot be resolved at startup
- **THEN** off-Space support is disabled, the app launches normally, and enumeration/raising use the current-Space path

#### Scenario: Private APIs available
- **WHEN** all required private symbols resolve
- **THEN** all-Spaces enumeration and off-Space raising are enabled

### Requirement: Off-Space thumbnails and titles degrade gracefully
The system SHALL show off-Space window thumbnails when available, and SHALL fall back to the app-icon placeholder and an app-name title when capture or an Accessibility title is unavailable.

#### Scenario: Off-Space thumbnail when capturable
- **WHEN** an off-Space window can be captured and Screen Recording is granted
- **THEN** its thumbnail is shown

#### Scenario: Off-Space window without resolvable title
- **WHEN** no Accessibility element or window title is available for an off-Space window
- **THEN** the card shows the app icon and the app name as the title

### Requirement: Raising never leaves a focus vacuum
Raising a window SHALL deterministically establish a key window — after a raise, exactly one application SHALL be frontmost with a key window, on the current Space or another Space. The raise SHALL always finish with an application activation fallback so a key window is established even if the SkyLight front/key handshake fails, and SHALL NOT leave a process fronted with no key window.

#### Scenario: Current-Space raise leaves a key window
- **WHEN** a current-Space window is committed
- **THEN** its application becomes frontmost with that window as the key window, and clicks/scroll/keyboard reach it without any Mission Control intervention

#### Scenario: Off-Space raise leaves a key window
- **WHEN** an off-Space window is committed
- **THEN** the Space switches once and its application becomes frontmost with a key window; if the SkyLight key handshake fails, the activation fallback still establishes key state

#### Scenario: No system-wide input freeze after repeated switches
- **WHEN** the user commits many window switches in succession across current- and off-Space targets
- **THEN** the system continues to accept clicks, scroll, and keyboard input after every commit (no focus vacuum)

#### Scenario: Key-window handshake reports failure
- **WHEN** the low-level key-window event posts fail
- **THEN** the raise falls back to Accessibility focus plus application activation rather than leaving no key window

### Requirement: Raising under Stage Manager does not start a focus war
When Stage Manager is enabled, raising a current-Space window SHALL NOT assert the per-application focus singletons (the window's `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`) — those make WindowManager's stage-front arbiter oscillate between windows of one application that share the center stage. It SHALL instead raise with `kAXRaiseAction` and activate the application. For an off-Space raise, WindowManager additionally grabs frontmost — leaving the application with no key window (a focus vacuum) — within roughly half a second after the Space switch settles; the system SHALL detect this and re-front the target window via a bounded, polling hold-guard, so keyboard focus is restored without user intervention and without a sustained window-order storm. The focus-vacuum protections (activation fallback and the post-commit watchdog) SHALL remain in effect. When Stage Manager is disabled, the raise SHALL be unchanged.

#### Scenario: Co-staged same-app windows do not oscillate
- **WHEN** Stage Manager is enabled with app-window grouping and two windows of one application share the center stage, and the user commits to one of them
- **THEN** focus settles on a window of that application and does not oscillate between the two windows (no sustained window-order churn after the commit)

#### Scenario: Chosen window still becomes frontmost under Stage Manager
- **WHEN** a current-Space window is committed while Stage Manager is enabled
- **THEN** the window is raised with `kAXRaiseAction` and its application is activated so it becomes frontmost with keyboard focus, without writing `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`

#### Scenario: Off-Space focus is restored after WindowManager steals it
- **WHEN** an off-Space window is committed while Stage Manager is enabled and WindowManager grabs frontmost (leaving no key window) shortly after the Space switch
- **THEN** the polling hold-guard re-fronts the target window so it regains keyboard focus within a fraction of a second, with no sustained reorder storm

#### Scenario: Behavior unchanged when Stage Manager is off
- **WHEN** Stage Manager is disabled and a window is committed
- **THEN** the full Accessibility sequence (`kAXRaiseAction` + `kAXMainAttribute` + the application's `kAXFocusedWindowAttribute`) plus activation runs exactly as before, and no hold-guard is needed (WindowManager does not steal frontmost)

#### Scenario: Vacuum safety net retained under Stage Manager
- **WHEN** Stage Manager is enabled and a raise would otherwise leave the frontmost application with no key window
- **THEN** the activation fallback and the +180ms watchdog still establish a key window (no focus vacuum)

### Requirement: Diagnostics expose off-Space listing and thumbnail fidelity
The `--diag` diagnostic report SHALL expose enough state to choose the off-Space listing and thumbnail discriminators from observed data rather than assumption. The report SHALL include a per-candidate dump of every layer-0 window owned by a regular app — including windows that are dropped — recording, for each: owner, name, bounds, alpha, on-screen flag, whether a live (brute-force or current-Space) Accessibility element resolved, whether a cached element exists, and the resulting listing decision. (CoreGraphicsServices Space membership was dumped during investigation but proved inert on this OS — it returns the same count for every window — so it is not a required field.) This dump SHALL make the ghost discriminator observable — that a ghost (closed-but-process-alive window, dialog/sheet, or background-agent surface) has no Accessibility element on any Space (live and cached both absent) while every genuine window has at least one. The thumbnail path SHALL be able to record the ScreenCaptureKit-reported window frame alongside the window's logical frame so the set-aside/off-screen signal can be confirmed.

#### Scenario: Per-candidate listing decision is dumped
- **WHEN** the diagnostic report is generated
- **THEN** for each layer-0 regular-app window it records the CoreGraphicsServices attributes, whether a live and/or cached Accessibility element resolved, and the listing decision, so that ghosts (no Accessibility element anywhere) are distinguishable from genuine off-Space windows

#### Scenario: Thumbnail frame comparison is observable
- **WHEN** a thumbnail capture runs with frame logging enabled
- **THEN** the ScreenCaptureKit-reported frame and the window's logical frame are recorded so a degraded (set-aside/off-screen) capture can be distinguished from a clean one

### Requirement: Window-level focus tracking from all sources
The system SHALL maintain a per-`CGWindowID` focus-recency history that feeds the switcher ordering, updated from every focus source — not only the switcher's own commits — so the last-focused and second-to-last-focused windows are accurate even when the user switched outside the switcher. The system SHALL promote a window to most-recent on each of: (a) committing/raising it via the switcher, (b) its application becoming frontmost (resolving that application's focused window via Accessibility), and (c) an external focused-window change within the frontmost application (a click on another window, `Cmd-\``, or a Mission Control selection), observed live via an Accessibility focused-window observer on the frontmost application. The observer SHALL follow the frontmost application (retargeted on activation) rather than registering on every application. When Accessibility access is unavailable, tracking SHALL degrade to commit and application-activation sources without error and without introducing any new permission prompt. Closed windows SHALL be evicted from the history so it stays bounded to live windows and a reused-feeling id can never mis-rank.

#### Scenario: External within-app switch updates recency
- **WHEN** the user, without using the switcher, focuses a different window of the frontmost application (clicks it, presses `Cmd-\``, or picks it in Mission Control)
- **THEN** that window becomes the most-recent in the focus history, so the next time the switcher opens it is first and the prior window is second

#### Scenario: Cross-app switch updates recency
- **WHEN** the user activates another application outside the switcher (e.g. Cmd-Tab or clicking its window)
- **THEN** that application's focused window becomes the most-recent in the focus history

#### Scenario: Switcher commit updates recency
- **WHEN** the user commits a window in the switcher
- **THEN** that window becomes the most-recent in the focus history

#### Scenario: Current window resolved at snapshot as a backstop
- **WHEN** the overlay is shown and the frontmost application's focused window id is resolvable
- **THEN** it is promoted to most-recent before ordering, so the current window is first even if an earlier focus event did not resolve a window id

#### Scenario: Degrades without Accessibility
- **WHEN** Accessibility access is not granted
- **THEN** focus tracking continues from commit and application-activation sources without raising a new permission prompt, and no error surfaces

#### Scenario: Closed windows are evicted
- **WHEN** a window in the focus history no longer exists at snapshot time
- **THEN** it is removed from the history so the list stays bounded to live windows

### Requirement: App-scoped current-Space enumeration including minimized windows
The system SHALL provide an enumeration variant that returns the normal windows of a **single application** on the **current Space only**, and — unlike the switcher's all-Spaces enumeration — **including minimized windows**. Each returned window SHALL carry whether it is minimized so a consumer can badge it and choose the correct commit path. This variant SHALL NOT change the switcher's enumeration (all Spaces, minimized excluded); it is an additive mode. When Accessibility access is unavailable, the variant SHALL degrade without error and without introducing any new permission prompt.

#### Scenario: Returns only the requested app on the current Space
- **WHEN** the app-scoped current-Space variant is queried for application A
- **THEN** it returns A's normal windows on the current Space and no windows of other applications or other Spaces

#### Scenario: Includes minimized windows flagged as minimized
- **WHEN** application A has minimized windows on the current Space
- **THEN** those windows are included in the result and each is flagged as minimized

#### Scenario: Switcher enumeration is unchanged
- **WHEN** the switcher's enumeration runs
- **THEN** it still spans all Spaces and excludes minimized windows, unaffected by the new variant

#### Scenario: Degrades without Accessibility
- **WHEN** Accessibility access is not granted
- **THEN** the variant returns no error and prompts for no new permission

### Requirement: Un-minimize then raise on commit of a minimized window
When a commit targets a **minimized** window, the system SHALL un-minimize it (clearing the window's Accessibility minimized state) and then raise it using the existing raise path, so it becomes frontmost with keyboard focus. The existing raise hardening (activation fallback, post-commit watchdog, and the Stage-Manager hold-guard) SHALL remain in effect. A commit targeting a non-minimized window SHALL raise exactly as before.

#### Scenario: Minimized window is restored and raised
- **WHEN** a commit targets a minimized window
- **THEN** the window is un-minimized and then raised to the front with keyboard focus

#### Scenario: Non-minimized commit is unchanged
- **WHEN** a commit targets a non-minimized window
- **THEN** the existing raise sequence runs unchanged

#### Scenario: Raise hardening still applies after un-minimize
- **WHEN** a minimized window is un-minimized and raised
- **THEN** the activation fallback, post-commit watchdog, and Stage-Manager hold-guard still establish and hold keyboard focus

