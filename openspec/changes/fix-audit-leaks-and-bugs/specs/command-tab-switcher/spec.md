## MODIFIED Requirements

### Requirement: One switcher session at a time

The keyboard driver and the trackpad gesture SHALL share the switcher such that only one owns it at a time. While a trackpad switcher gesture holds the overlay, the keyboard driver SHALL NOT act on ⌘-Tab. While a keyboard session holds the overlay, a three-finger trackpad touch SHALL be refused **entirely**: it SHALL NOT activate, step, commit, or cancel anything until every finger lifts — it can neither steer the keyboard session's highlight nor dismiss its overlay. After a session ends (commit or cancel), either driver SHALL be able to open the switcher again.

#### Scenario: Keyboard driver defers to an active trackpad gesture

- **WHEN** a trackpad switcher gesture is holding the overlay open and the user presses ⌘-Tab
- **THEN** the keyboard driver takes no action on the overlay

#### Scenario: A three-finger touch during a keyboard session is inert

- **WHEN** a keyboard session holds the overlay and three fingers rest on or scrub across the trackpad
- **THEN** the highlight does not move, the overlay stays open, and lifting the fingers neither commits nor cancels the session

#### Scenario: Either driver can reopen after a session ends

- **WHEN** a keyboard session has just committed or canceled
- **THEN** a subsequent ⌘-Tab (or trackpad gesture) opens the switcher normally

### Requirement: No new permission and a self-healing tap

The keyboard driver SHALL require no permission beyond the Input Monitoring the app already holds, and SHALL NOT require a re-login to enable or disable. The keyboard event tap SHALL re-enable itself if the system disables it (tap timeout or user-input disable), so interception survives the system's periodic tap suspensions — and on every re-enable, and on every key event, it SHALL re-derive whether ⌘ is held from the authoritative modifier flags rather than from the last transition it observed, so a ⌘ release delivered while the tap was disabled never leaves bare Tab, Escape, or the arrow keys swallowed.

#### Scenario: No new grant is requested

- **WHEN** the user enables the feature and Input Monitoring is already granted
- **THEN** interception begins with no additional permission prompt and no re-login

#### Scenario: Tap self-heals after the system disables it

- **WHEN** the system disables the keyboard event tap (timeout or user-input disable)
- **THEN** the tap is re-enabled and ⌘-Tab interception continues

#### Scenario: A ⌘ release missed during a tap stall is recovered

- **WHEN** ⌘ is released while the tap is disabled and the tap is later re-enabled
- **THEN** the session commits and a following bare Tab reaches the focused application
