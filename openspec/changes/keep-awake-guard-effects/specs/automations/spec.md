## ADDED Requirements

### Requirement: Keep Awake can dim the keyboard backlight as part of the session
The Keep Awake item SHALL carry a per-item **keyboard backlight** opt-in (default off, decode-safe: an item saved before the option existed decodes to off with no schema bump). When enabled, starting the session SHALL snapshot each controllable keyboard's backlight level and set it to zero; the existing heartbeat SHALL re-pin it to zero (defeating auto-illumination raising it); and **every** stop path SHALL restore each snapshotted keyboard to its captured level. Backlight control uses no new permission; a keyboard whose backlight cannot be read or set SHALL be skipped — the session still starts and never fails or prompts.

#### Scenario: Backlight dims with the displays
- **WHEN** a Keep Awake item with the keyboard option enabled starts
- **THEN** every controllable keyboard backlight is captured and set to zero, alongside the display dim

#### Scenario: Heartbeat re-pins the backlight
- **WHEN** the session is active across a heartbeat and something (e.g. auto-illumination) raised the backlight
- **THEN** the heartbeat sets it back to zero

#### Scenario: Every stop restores the backlight
- **WHEN** the session stops by any path (input, re-fire, menu bar, quit, will-sleep)
- **THEN** each snapshotted keyboard returns to its captured level

#### Scenario: Unavailable backlight is skipped, never fails
- **WHEN** the backlight API or hardware is unavailable
- **THEN** the session starts and runs normally with the keyboard untouched (no crash, no prompt)

#### Scenario: Option off leaves the keyboard alone
- **WHEN** a Keep Awake item without the keyboard option starts and stops
- **THEN** the keyboard backlight is never read or written

### Requirement: Keep Awake can guard the Mac — any input stops it and locks the screen
The Keep Awake item SHALL carry a per-item **guard** opt-in (default off, decode-safe). When enabled, once the session has armed (the existing after-the-trigger-lifts rule), **any input** SHALL stop the session and **immediately lock the screen**: a trackpad contact (via the existing touch stream), a mouse move or click, or a key or modifier press (via passive event monitors requiring no new permission — the input is observed, not consumed). An input while guarded is an intentional end of the session: the session SHALL fully stop (assertion released, state restored) — there is no continued "working behind the lock" phase. The lock SHALL be issued **before** brightness restore, so unlocked screen content is never presented en route to the lock screen.

Input monitors SHALL be installed only when the guard option is on, only while the session is armed, and SHALL be removed before any other stop effect runs. Input events synthesized by the app's own process (e.g. the computer-use agent posting CGEvents) SHALL NOT trip the guard.

Only the **input** stop path locks. Explicit stops (re-firing the item, the menu-bar Stop) and teardown stops (app quit, system will-sleep) SHALL never lock. When the guard option is off, stop behavior is unchanged from the base spec (trackpad touch only, no lock, no monitors).

#### Scenario: A stranger's touch hits the lock screen
- **WHEN** a guarded session is armed and any trackpad contact, mouse move/click, or key press occurs
- **THEN** the screen locks immediately, the session stops fully (brightness and backlight restored behind the lock, assertion released), and unlocking requires authentication (e.g. Touch ID)

#### Scenario: Lock precedes restore
- **WHEN** a guarded session stops on input
- **THEN** the lock is issued before display brightness is restored (no unlocked-desktop flash)

#### Scenario: The triggering gesture cannot lock
- **WHEN** a guarded session has started but the trackpad has not yet emptied once
- **THEN** residual contacts neither stop nor lock (not yet armed), and no input monitor is installed yet

#### Scenario: Teardown and explicit stops never lock
- **WHEN** a guarded session stops via quit, will-sleep, the menu bar, or a re-fire toggle
- **THEN** the session stops and restores normally and the screen is NOT locked

#### Scenario: The app's own synthetic input does not trip the guard
- **WHEN** a guarded session is armed and this app posts synthetic input events (an acting agent)
- **THEN** the session stays active and the screen does not lock

#### Scenario: Guard off means base behavior
- **WHEN** a session without the guard option is armed and a mouse move or key press occurs
- **THEN** nothing happens (no monitors are installed); only a trackpad touch stops it, without locking

### Requirement: The new session options are configured on the item
The launcher editor's automation inspector SHALL, for a Keep Awake item, show controls for the keyboard-backlight option and the guard option alongside the existing dim-level control, each with a plain-language description of what it does (including, for the guard, that unlocking is by normal authentication and that menu-bar/quit stops never lock). Both values SHALL persist with the item and round-trip; the same automation in different bands MAY carry different option combinations.

#### Scenario: Configure the options in the inspector
- **WHEN** the user selects a Keep Awake item in the editor
- **THEN** the inspector shows the keyboard-backlight and guard toggles with descriptions, and changes persist to that item

#### Scenario: Pre-existing items decode to both options off
- **WHEN** a favorites record written before these options existed is loaded
- **THEN** its Keep Awake items decode with both options off and behave exactly as before
