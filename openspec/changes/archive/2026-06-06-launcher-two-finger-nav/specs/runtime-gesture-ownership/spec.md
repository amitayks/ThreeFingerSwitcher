## MODIFIED Requirements

### Requirement: Scroll tap covers the launcher feature
The session scroll event tap SHALL run while the launcher opt-in is effective, in addition to when the Space-row opt-in is effective, so that the freed four-finger swipes — which macOS turns into plain scroll once their system assignment is removed — do not leak to the window under the cursor. The tap's consume rule SHALL consume scroll while **three or more fingers are in contact OR while the launcher overlay is open**. The launcher-open clause ensures that **two-finger movement during launcher navigation** is captured and does not scroll the window underneath. When the launcher overlay is **closed**, the consume rule reverts to three-or-more-contacts only, so normal two-finger scrolling passes through unchanged.

#### Scenario: Four-finger scroll is suppressed
- **WHEN** the launcher opt-in is effective and four fingers move (horizontally or vertically) over any window
- **THEN** the scroll is consumed and the background window does not scroll

#### Scenario: Tap runs for the launcher even if Space-row switching is off
- **WHEN** the launcher opt-in is effective and the Space-row opt-in is off
- **THEN** the scroll tap is running so four-finger scroll is suppressed

#### Scenario: Two-finger navigation is consumed while the launcher is open
- **WHEN** the launcher overlay is open and the user navigates with two fingers
- **THEN** the two-finger scroll is consumed and the window under the launcher does not scroll

#### Scenario: Two-finger scroll passes through when the launcher is closed
- **WHEN** the launcher overlay is not open and two fingers scroll
- **THEN** the scroll passes through and the window scrolls normally

#### Scenario: Tap stops when neither feature is effective
- **WHEN** neither the launcher opt-in nor the Space-row opt-in is effective (or the switcher is disabled)
- **THEN** the tap is stopped and the system handles scroll normally
