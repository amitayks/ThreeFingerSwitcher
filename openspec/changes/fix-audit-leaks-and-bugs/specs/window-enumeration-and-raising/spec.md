## MODIFIED Requirements

### Requirement: Thumbnails shown and refreshed on every overlay showing
The system SHALL display each window's thumbnail every time the overlay is shown — not only the first time — by applying any cached thumbnail immediately on show and refreshing (re-capturing) thumbnails so they stay current across repeated gestures. A refresh SHALL re-capture every cleanly-presented window (a cached frame is not a reason to skip; the cached frame shows meanwhile), subject to the cleanliness and motion gates below, so a slipped-through frame self-heals on the next sweep. A window that is not cleanly presented — minimized, parked off every display, or a Stage-Manager strip proxy (its displayed frame below the clean-scale threshold of its real Accessibility frame in either dimension) — SHALL be skipped and served from cache or the app icon, and a degraded capture SHALL never overwrite a clean cached frame. The cleanliness signals SHALL be evaluated against the window's current frame, and a capture across which the frame changed (the window was in motion) SHALL be discarded.

Refresh scheduling SHALL be: an **explicit** refresh — the overlay opening, or the displayed Space changing (trackpad edge crossing or ⌘-Tab row change) — SHALL supersede a sweep still in flight (it is refreshing the row the user just left) rather than be dropped; the **periodic** refresh SHALL skip a tick while a sweep is running (an idempotent refresh, never a queue). The opening sweep SHALL capture the visible Space's windows first and then, once, every other Space's windows in reel order, so a Space the user scrolls to is at most one opening old; the periodic sweep re-captures only the visible Space. Within a sweep, captures SHALL run a bounded number at a time (not strictly one after another) so a row lands within roughly one capture's latency, and the shareable-content listing SHALL be reused across a session's sweeps while it is fresh and lists every target. A window whose capture from a superseded sweep is still completing SHALL be waited for (bounded), not skipped by the next sweep. Live frames that land within one display frame of each other SHALL be published to the overlay together (one re-render), while a cached seed SHALL still apply immediately.

#### Scenario: Cached thumbnail shown on repeat gesture
- **WHEN** the overlay is shown again for a window whose thumbnail was captured on an earlier gesture
- **THEN** the cached thumbnail is applied immediately so the card shows the preview (not icon-only)

#### Scenario: Space switch during a running sweep refreshes the new row immediately
- **WHEN** the user switches the displayed Space while the periodic sweep is still refreshing the previous row
- **THEN** that sweep is superseded and the new row's capture starts at once, instead of waiting for the old sweep and a later idle tick

#### Scenario: Every row is captured once per opening
- **WHEN** the switcher opens with windows on several Spaces
- **THEN** the visible row's windows are captured first, then each other Space's windows once, so scrolling to another Space shows frames no older than this opening

#### Scenario: A batch of captures re-renders the reel once
- **WHEN** several captures complete within one display frame
- **THEN** they are published together in a single overlay update; a cached seed applied meanwhile is visible immediately

#### Scenario: Set-aside, minimized, or in-motion window keeps its clean cached thumbnail
- **WHEN** a refresh targets a window that is minimized, set aside under Stage Manager, parked off every display, or whose frame changed across the capture
- **THEN** the cached thumbnail (or app icon) is kept and no degraded or in-motion image is stored

#### Scenario: No duplicate concurrent captures
- **WHEN** a capture for a window id is already in flight
- **THEN** a second capture for the same id waits for it (bounded) rather than starting concurrently, and is not skipped outright

#### Scenario: Fallback unchanged when capture unavailable
- **WHEN** Screen Recording is not granted or a capture fails
- **THEN** the card falls back to the app-icon placeholder

### Requirement: Un-minimize then raise on commit of a minimized window
When a commit targets a **minimized** window, the system SHALL un-minimize it (clearing the window's Accessibility minimized state) and then raise it using the existing raise path once the un-minimize animation has settled, so it becomes frontmost with keyboard focus. The deferred raise SHALL be superseded by any newer commit, peek, or user input that arrives before it fires (it must not raise the window over whatever the user did next). If the minimized-state write fails, the commit SHALL report failure (so the Dock path surfaces its bounded error card) rather than a false success. A commit targeting a non-minimized window SHALL raise exactly as before.

#### Scenario: Minimized window is restored and raised
- **WHEN** a commit targets a minimized window
- **THEN** the window is un-minimized and then raised to the front with keyboard focus once the animation settles

#### Scenario: A newer action cancels the deferred raise
- **WHEN** the user commits or peeks another window, or clicks elsewhere, before the deferred raise fires
- **THEN** the deferred raise does not run

#### Scenario: Failed un-minimize is reported
- **WHEN** the Accessibility minimized-state write fails
- **THEN** the commit returns failure and no raise is scheduled

## ADDED Requirements

### Requirement: Post-commit focus guards yield to user input
The post-commit focus watchdog and the off-Space / Stage-Manager hold-guard SHALL be released the moment the user acts — a mouse button press, or a keyboard shortcut carrying the ⌘ modifier — and by a Dock-preview peek, so a deliberate switch-away within the guard window is never undone. Plain typing SHALL NOT release them (the target has keyboard focus then). The monitor that detects user input SHALL be installed only while a guard is pending and SHALL never consume events.

#### Scenario: Click elsewhere during the hold window
- **WHEN** the user clicks another application's window within the hold-guard window after an off-Space commit
- **THEN** the guard stops and the clicked window stays frontmost

#### Scenario: Steal still corrected when the user has not acted
- **WHEN** the destination Space steals frontmost after an off-Space commit and the user has not pressed a mouse button or a ⌘ shortcut
- **THEN** the hold-guard re-fronts the committed window as before

### Requirement: Private Spaces APIs are consumed with correct ownership
Every private CoreGraphics/SkyLight function whose name follows the Create/Copy rule SHALL be bound as returning an unmanaged reference and consumed with a retained take, so each returned object is released exactly once and repeated calls do not grow the process.

#### Scenario: Repeated enumeration does not leak
- **WHEN** the Space model and per-Space window lists are read thousands of times over a session
- **THEN** the process's resident memory does not grow with the number of reads
