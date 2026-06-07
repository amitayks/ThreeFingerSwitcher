## ADDED Requirements

### Requirement: Scroll tap covers two-finger switcher navigation

The session scroll event tap's consume rule SHALL additionally consume scroll **while the switcher overlay is open**, so that the **two-finger movement during switcher navigation** (after a three-finger trigger relaxes to two fingers) is captured and does not scroll the window underneath. The full consume rule SHALL therefore consume scroll while **three or more fingers are in contact, OR the launcher overlay is open, OR the switcher overlay is open**. When the switcher overlay is **closed**, the switcher clause does not apply, so normal two-finger scrolling passes through unchanged. This clause SHALL require only the Accessibility permission the app already holds (no Input Monitoring, no re-login).

#### Scenario: Two-finger navigation is consumed while the switcher is open
- **WHEN** the switcher overlay is open and the user navigates with two fingers
- **THEN** the two-finger scroll is consumed and the window under the switcher does not scroll

#### Scenario: Two-finger scroll passes through when the switcher is closed
- **WHEN** the switcher overlay is not open (and no other consume condition holds) and two fingers scroll
- **THEN** the scroll passes through and the window scrolls normally

## MODIFIED Requirements

### Requirement: Consume the freed three-finger scroll at runtime
When the Space-row switching opt-in is effective, the system SHALL run a session scroll event tap that consumes scroll-wheel events while three or more fingers are in contact, so the freed three-finger vertical gesture (which macOS turns into a plain scroll once its system assignment is removed) does not leak to the window under the cursor. Two-finger scrolling SHALL pass through untouched **except while a tap-owning overlay (launcher or switcher) is open**. The tap SHALL require only the Accessibility permission the app already holds for window raising (Input Monitoring SHALL NOT be required). The tap SHALL run **whenever the switcher is enabled** — two-finger switcher navigation depends on it, so it is no longer gated on the Space-row or launcher opt-ins being effective.

#### Scenario: Three-finger scroll is suppressed
- **WHEN** the feature is effective and three fingers move vertically (over any window)
- **THEN** the scroll is consumed and the background window does not scroll

#### Scenario: Two-finger scroll is unaffected
- **WHEN** two fingers scroll and no tap-owning overlay (launcher or switcher) is open
- **THEN** the scroll passes through and the window scrolls normally

#### Scenario: Tap runs whenever the switcher is enabled
- **WHEN** the switcher is enabled
- **THEN** the session scroll tap is running (covering the three-finger, launcher, and two-finger-switcher consume cases); and **WHEN** the switcher is disabled
- **THEN** the tap is stopped (the system handles scroll normally)

### Requirement: Scroll tap covers the launcher feature
The session scroll event tap SHALL run while the launcher opt-in is effective, in addition to when the Space-row opt-in is effective, so that the freed four-finger swipes — which macOS turns into plain scroll once their system assignment is removed — do not leak to the window under the cursor. The tap's consume rule SHALL consume scroll while **three or more fingers are in contact OR while the launcher overlay is open OR while the switcher overlay is open**. The launcher-open clause ensures that **two-finger movement during launcher navigation** is captured and does not scroll the window underneath. When the launcher overlay is **closed**, the launcher clause reverts so normal two-finger scrolling passes through unchanged (unless another consume condition, such as the switcher overlay being open, holds).

#### Scenario: Four-finger scroll is suppressed
- **WHEN** the launcher opt-in is effective and four fingers move (horizontally or vertically) over any window
- **THEN** the scroll is consumed and the background window does not scroll

#### Scenario: Tap runs for the launcher even if Space-row switching is off
- **WHEN** the launcher opt-in is effective and the Space-row opt-in is off
- **THEN** the scroll tap is running so four-finger scroll is suppressed

#### Scenario: Two-finger navigation is consumed while the launcher is open
- **WHEN** the launcher overlay is open and the user navigates with two fingers
- **THEN** the two-finger scroll is consumed and the window under the launcher does not scroll

#### Scenario: Two-finger scroll passes through when no overlay is open
- **WHEN** neither the launcher nor the switcher overlay is open and two fingers scroll
- **THEN** the scroll passes through and the window scrolls normally

#### Scenario: Tap stops only when the switcher is disabled
- **WHEN** the switcher is disabled
- **THEN** the tap is stopped and the system handles scroll normally
