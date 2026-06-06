## ADDED Requirements

### Requirement: Scroll tap covers the launcher feature
The session scroll event tap SHALL run while the launcher opt-in is effective, in addition to when the Space-row opt-in is effective, so that the freed four-finger swipes — which macOS turns into plain scroll once their system assignment is removed — do not leak to the window under the cursor. The tap's consume rule (consume while three or more fingers are in contact) already covers four-finger contact, on both axes, and SHALL remain unchanged. Two-finger scrolling SHALL continue to pass through.

#### Scenario: Four-finger scroll is suppressed
- **WHEN** the launcher opt-in is effective and four fingers move (horizontally or vertically) over any window
- **THEN** the scroll is consumed and the background window does not scroll

#### Scenario: Tap runs for the launcher even if Space-row switching is off
- **WHEN** the launcher opt-in is effective and the Space-row opt-in is off
- **THEN** the scroll tap is running so four-finger scroll is suppressed

#### Scenario: Tap stops when neither feature is effective
- **WHEN** neither the launcher opt-in nor the Space-row opt-in is effective (or the switcher is disabled)
- **THEN** the tap is stopped and the system handles scroll normally

#### Scenario: Two-finger scroll still passes through
- **WHEN** the launcher opt-in is effective and two fingers scroll
- **THEN** the scroll passes through and the window scrolls normally
