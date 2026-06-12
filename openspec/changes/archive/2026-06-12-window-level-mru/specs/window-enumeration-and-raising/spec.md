## MODIFIED Requirements

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

## ADDED Requirements

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
