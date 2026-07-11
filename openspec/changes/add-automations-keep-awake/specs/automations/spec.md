## ADDED Requirements

### Requirement: Automations are stateful, toggle-style launcher items
The system SHALL support **automations**: launcher items that toggle a persistent mode rather than run a one-shot effect. Firing an automation item while its mode is inactive SHALL **start** the automation; firing it again (or any of the defined stop paths) SHALL **stop** it. An automation SHALL be modeled as a first-class launch-item kind, added to a band from the editor like any other item, so the same automation MAY appear in more than one band. The set of automations SHALL be extensible; v1 defines exactly one: **Keep Awake**.

#### Scenario: Firing toggles the mode
- **WHEN** an automation item is fired while its mode is inactive
- **THEN** the automation starts

- **WHEN** the same automation is fired again while active (or another stop path fires)
- **THEN** the automation stops

#### Scenario: Authored like any item
- **WHEN** the user browses the editor's Automations source and picks one
- **THEN** an automation item is added to the active band, movable and duplicable like any other item

### Requirement: Keep Awake blocks sleep and lock while dimming the displays
Keep Awake SHALL, while active, prevent the Mac from sleeping (system sleep), the display from sleeping, and the idle screen from locking, so background work keeps running. It SHALL achieve this by holding a system activity assertion for the duration (blocking idle system sleep and idle display sleep), acquired via public OS API and requiring **no new permission or entitlement**. On start it SHALL set every active display to its **configured dim level** (minimum by default) so the screen is dark but on. Keeping the display on but dark is deliberate — the screen is not put to sleep; it is dimmed.

The system SHALL NOT claim to prevent sleep in situations the OS forces regardless of assertions — notably a laptop whose lid is closed (except in clamshell mode on power with an external display) will still sleep. This is an accepted limitation, not a failure.

#### Scenario: Active Keep Awake blocks idle sleep and lock
- **WHEN** Keep Awake is active and the machine would otherwise idle into display sleep, system sleep, or an idle lock
- **THEN** none of those occur while it stays active, and no new permission is requested

#### Scenario: Displays dimmed, not slept
- **WHEN** Keep Awake starts
- **THEN** every active display whose brightness can be controlled is set to minimum, and the displays remain on (not asleep)

#### Scenario: Undimmable display is skipped, never fails
- **WHEN** a connected display's brightness cannot be read or set
- **THEN** that display is left unchanged and Keep Awake still starts (no crash, no permission prompt)

### Requirement: Keep Awake's dim level is configurable per item, with an in-editor description
The Keep Awake automation item SHALL carry a configurable **dim level** (0–100%) that sets how dark the displays go while active; absent a configured value it SHALL default to minimum (0%). The value SHALL persist with the item and be decode-safe (an item saved before the level existed decodes to the default with no schema bump). The launcher editor's item inspector SHALL, for an automation item, show a plain-language **description of what the automation does** and a control to set the dim level. Stopping SHALL always restore each display to the brightness captured at start regardless of the configured dim level (the level controls only the active "in" brightness, not the restore).

#### Scenario: Configure the dim level in the inspector
- **WHEN** the user selects a Keep Awake item in the editor
- **THEN** the inspector shows a description of the automation and a dim-level control, and changing it persists to the item

#### Scenario: Dim to the configured level
- **WHEN** Keep Awake with a configured dim level of N% is started
- **THEN** every controllable active display is set to N% (not necessarily minimum), and the periodic heartbeat re-pins to N%

#### Scenario: Restore is independent of the dim level
- **WHEN** Keep Awake stops
- **THEN** each dimmed display returns to the brightness captured at start, whatever the configured dim level was

### Requirement: Keep Awake re-asserts on a periodic heartbeat
While Keep Awake is active, the system SHALL, on a periodic heartbeat of approximately five minutes, re-pin every controllable active display to minimum brightness and re-declare user activity, as a safety net against another process raising the brightness or an idle timer the sleep assertion does not cover. The heartbeat SHALL be a plain timer performing no continuously-animating UI work (so it cannot cause a runaway idle-CPU loop).

#### Scenario: Heartbeat re-pins brightness
- **WHEN** Keep Awake has been active across a heartbeat interval and the brightness was changed by something else
- **THEN** the next heartbeat re-sets the active displays to minimum

### Requirement: A trackpad touch stops Keep Awake, armed only after the trigger lifts
Keep Awake SHALL stop on the next trackpad contact **after** the triggering gesture has fully lifted. Concretely: after starting, the automation SHALL wait until the trackpad reports zero contacts once (the firing gesture released), then **arm**; the next finger-down while armed SHALL stop the automation. This ensures the triggering gesture itself can never immediately cancel the automation. The stopping touch SHALL be **non-consuming** — it stops Keep Awake as a side effect and still flows through as a normal gesture.

#### Scenario: The triggering gesture cannot self-cancel
- **WHEN** Keep Awake has just started and residual contacts from the firing gesture are still (or again) present before the trackpad has emptied
- **THEN** Keep Awake stays active (it is not yet armed)

#### Scenario: Return-touch stops it
- **WHEN** Keep Awake has armed (the trackpad emptied once) and the user next touches the trackpad
- **THEN** Keep Awake stops, and the touch is not swallowed (a normal gesture still proceeds)

### Requirement: Stopping restores state, and teardown is guaranteed and idempotent
Stopping Keep Awake SHALL restore each display to the brightness captured at start, release the activity assertion, and stop the heartbeat — exactly once and safely if already stopped (idempotent). Keep Awake SHALL additionally be force-stopped when the app is quitting and when the system is about to sleep, so a dimmed screen and a held assertion are never left stranded. Because the screen is dimmed near-black while active, the restore SHALL be robust: a menu-bar affordance SHALL show that Keep Awake is active and allow stopping it as a fallback, and quit/sleep SHALL restore brightness even if no trackpad touch occurred.

#### Scenario: Stop restores the captured brightness
- **WHEN** Keep Awake stops by any path
- **THEN** every display it dimmed is set back to its captured brightness and the assertion is released

#### Scenario: Idempotent stop
- **WHEN** a stop path fires for a Keep Awake that is already stopped
- **THEN** nothing happens (no double-restore, no crash)

#### Scenario: Quit restores brightness
- **WHEN** the app quits while Keep Awake is active
- **THEN** the displays are restored to their captured brightness before the process exits

#### Scenario: Menu-bar fallback stop
- **WHEN** Keep Awake is active
- **THEN** the menu bar shows it is active and offers to stop it, restoring brightness when chosen
