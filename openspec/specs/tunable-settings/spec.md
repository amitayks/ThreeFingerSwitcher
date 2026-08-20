# tunable-settings Specification

## Purpose

Define the settings model, persistence, defaults, and Settings UI for the switcher's sensitivity, stepping, and behavior tunables.
## Requirements
### Requirement: Tunable gesture parameters
The system SHALL expose tunable parameters with sensible defaults: activation threshold, axis-lock ratio, step distance ("one window per N"), wrap-vs-clamp at list ends, direction (natural/reverse), velocity smoothing factor, exact-three-fingers requirement, and inclusion of non-standard windows in the switcher list (default off — the strict standard-window gate).

#### Scenario: Defaults applied on first run
- **WHEN** the app runs for the first time
- **THEN** all tunables have sensible default values and the switcher is usable without configuration

#### Scenario: Non-standard window inclusion is a pure behavior tunable
- **WHEN** the user turns on "include non-standard windows"
- **THEN** the switcher lists windows that don't report the standard-window subrole (per the window-enumeration-and-raising gate), the change takes effect on the next gesture without a restart, and "reset to defaults" restores it to off (it has no system side effect, permission, or download to preserve)

#### Scenario: Changing step distance changes stepping
- **WHEN** the user increases the step distance
- **THEN** more finger travel is required to advance the selection by one window

#### Scenario: Direction inversion
- **WHEN** the user sets direction to reverse
- **THEN** sliding right moves the selection in the opposite direction from the natural setting

### Requirement: Persisted settings
The system SHALL persist settings across launches and apply them immediately when changed.

#### Scenario: Settings survive restart
- **WHEN** the user changes a setting and relaunches the app
- **THEN** the changed value is retained

#### Scenario: Live application
- **WHEN** the user changes a tunable while the app is running
- **THEN** the new value takes effect on the next gesture without requiring a restart

### Requirement: Settings UI
The system SHALL provide the configuration UI to view and edit all tunables as the **Hub** window (its Overview and per-feature pages), reachable from the status menu. There SHALL be no separate Settings window; wherever this and other requirements refer to "the Settings UI," that UI is provided by the Hub.

#### Scenario: Open settings from menu
- **WHEN** the user opens configuration from the status menu
- **THEN** the Hub opens showing the tunables on their feature pages with their current values

#### Scenario: Reset to defaults
- **WHEN** the user chooses to reset
- **THEN** all tunables return to their default values

### Requirement: Diagnostics visibility preference and in-Settings setup access
The system SHALL expose a "show diagnostic tools" preference, off by default, that controls whether the diagnostic actions (write diagnostics, copy focus log) are available in the Hub's General page. It SHALL persist across launches and SHALL return to off on reset-to-defaults. The Hub SHALL additionally provide access to Setup & Permissions (its Setup page) and — when a Mission Control backup exists — restoring the native three-finger up/down (Mission Control) gesture.

#### Scenario: Diagnostics preference off by default
- **WHEN** the app runs for the first time
- **THEN** the show-diagnostics preference is off and the diagnostic actions are not shown in the Hub

#### Scenario: Diagnostics preference persists
- **WHEN** the user enables the show-diagnostics preference and relaunches
- **THEN** the preference remains enabled

#### Scenario: Reset turns diagnostics visibility off
- **WHEN** the user resets to defaults
- **THEN** the show-diagnostics preference returns to off

#### Scenario: Diagnostics appear in the Hub when enabled
- **WHEN** the user enables the show-diagnostics preference
- **THEN** the write-diagnostics and copy-focus-log actions appear on the Hub's General page

#### Scenario: Setup and Mission Control restore live in the Hub
- **WHEN** the user opens the Hub
- **THEN** it provides a Setup & Permissions page, and — when a Mission Control backup exists — an entry to restore the native three-finger up/down gesture

### Requirement: Space-row switching opt-in binds feature and system change
The system SHALL expose a single "Space-row switching" opt-in, off by default, that binds together (a) the recognizer's vertical row stepping and (b) the relocation of the native three-finger vertical gesture to four fingers. The two SHALL NOT be independently enabled: turning the opt-in on requests both, and turning it off reverts both. The opt-in SHALL persist across launches and be reachable from the Settings UI and surfaced during onboarding.

#### Scenario: Off by default
- **WHEN** the app runs for the first time
- **THEN** Space-row switching is off, the recognizer does not perform row stepping, and the native three-finger vertical gesture is left untouched

#### Scenario: Enabling requests both sides together
- **WHEN** the user enables Space-row switching
- **THEN** the app relocates the native three-finger vertical gesture to four fingers (with consent) and enables vertical row stepping once that relocation is effective

#### Scenario: Disabling reverts both sides together
- **WHEN** the user disables Space-row switching
- **THEN** the app restores the original vertical trackpad values and the recognizer stops performing row stepping

#### Scenario: Opt-in persists across launches
- **WHEN** the user enables Space-row switching and relaunches the app
- **THEN** the opt-in remains enabled and is reapplied

### Requirement: Vertical row-switching tunables
The system SHALL expose tunable parameters for vertical Space-row switching: a row-step distance (vertical travel per row step, defaulting larger than the horizontal step distance) and a reverse-vertical-direction toggle. Both SHALL persist and appear in the Settings UI. These tunables SHALL take effect only while the Space-row switching opt-in is enabled; when the opt-in is off they have no behavioral effect because no row stepping occurs.

#### Scenario: Row-step distance defaults larger than horizontal step
- **WHEN** the app runs for the first time
- **THEN** the row-step distance default is larger than the horizontal step distance so rows are harder to trigger than window steps

#### Scenario: Changing row-step distance changes row sensitivity
- **WHEN** the Space-row switching opt-in is enabled and the user increases the row-step distance
- **THEN** more vertical travel is required to switch Space-rows

#### Scenario: Reverse vertical persists
- **WHEN** the user toggles reverse-vertical and relaunches
- **THEN** the setting is retained and applied when the opt-in is enabled

#### Scenario: Tunables inert while opt-in is off
- **WHEN** the Space-row switching opt-in is off
- **THEN** changing the row-step distance or reverse-vertical setting produces no row stepping

### Requirement: Launcher opt-in binds feature and four-finger native free
The system SHALL expose a single launcher opt-in, off by default, that binds together (a) the recognizer emitting four-finger launcher intents and (b) freeing the native four-finger horizontal and vertical swipe gestures. The two SHALL NOT be independently enabled: enabling requests both, and disabling reverts both. The opt-in SHALL persist across launches and be reachable from the Settings UI and surfaced during onboarding.

#### Scenario: Off by default
- **WHEN** the app runs for the first time
- **THEN** the launcher opt-in is off, four fingers do not open the launcher, and the native four-finger swipe gestures are untouched

#### Scenario: Enabling requests both sides together
- **WHEN** the user enables the launcher opt-in
- **THEN** the app frees the native four-finger swipe gestures (with consent) and enables four-finger launcher intents once the change is effective

#### Scenario: Disabling reverts both sides together
- **WHEN** the user disables the launcher opt-in
- **THEN** the app restores the native four-finger swipe values and the recognizer stops emitting launcher intents

#### Scenario: Opt-in persists across launches
- **WHEN** the user enables the launcher opt-in and relaunches the app
- **THEN** the opt-in remains enabled and is reapplied

### Requirement: Launcher tunables
The system SHALL expose tunable parameters for the launcher: a four-finger activation threshold, an item-step distance, a context-step distance, and a dwell-to-arm duration. The item-step and context-step SHALL parameterize **accumulated travel distance** per step (odometer travel) for item movement versus band switching respectively (a coarser context step keeps band switching deliberate while item movement stays fine). All SHALL persist and appear in the Settings UI. These tunables SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Dwell duration default is brief but deliberate
- **WHEN** the app runs for the first time
- **THEN** the dwell-to-arm duration defaults to a brief deliberate value (on the order of half a second), not a full second

#### Scenario: Changing dwell changes arm time
- **WHEN** the launcher opt-in is enabled and the user increases the dwell-to-arm duration
- **THEN** an item must be rested on longer before it arms

#### Scenario: Changing context-step distance changes band sensitivity
- **WHEN** the launcher opt-in is enabled and the user increases the context-step distance
- **THEN** more vertical travel is required to switch context bands

#### Scenario: Launcher tunables persist
- **WHEN** the user changes a launcher tunable and relaunches
- **THEN** the value is retained and applied when the opt-in is enabled

### Requirement: Clipboard history opt-in and tunables
The settings SHALL expose a "Keep clipboard history" opt-in that defaults to OFF and gates both the background recorder and the launcher's Clipboard band. Unlike the Space-row and launcher opt-ins, this opt-in SHALL NOT relocate any native gesture, require a re-login, or request a new permission — it only enables local recording and the synthetic band. The settings SHALL also expose tunables for the recent-window size (how many entries the band shows), retention caps (count, total bytes, age), the change-counter poll interval, the edge-scroll-acceleration sensitivity, and the **pin-flick distance** (how deliberate a sideways flick must be to pin / leave the band), plus controls to **pause** recording, **clear** history, and manage the **excluded applications** list. Settings saved before this feature SHALL load unchanged with the opt-in OFF and no clipboard data.

#### Scenario: Opt-in defaults off and gates the feature
- **WHEN** the app loads with no prior clipboard settings
- **THEN** "Keep clipboard history" is OFF, nothing is recorded, and no Clipboard band appears

#### Scenario: Toggling the opt-in needs no re-login or permission
- **WHEN** the user turns the opt-in on
- **THEN** recording and the Clipboard band become active immediately without a re-login, native-gesture change, or new permission prompt

#### Scenario: Tunables and controls are adjustable in settings
- **WHEN** the user opens settings with the opt-in on
- **THEN** they can adjust the recent-window size, retention caps, poll interval, and edge-acceleration sensitivity, and can pause recording, clear history, and edit the excluded-apps list

#### Scenario: Older settings load with the feature off
- **WHEN** settings saved before this feature are loaded
- **THEN** they decode successfully with the opt-in OFF and no clipboard history, and existing settings are not reset

### Requirement: Include-minimized-windows opt-in
The system SHALL expose an "include minimized windows in the switcher" opt-in, **off by default**, that makes minimized windows appear in the three-finger switcher and the ⌘-Tab reel — each flagged and badged as minimized — with selection **un-minimizing the window in place** and raising it. It SHALL be independent of the include-non-standard-windows setting (either may be on without the other). It SHALL persist across launches, take effect on the next gesture without a restart, and appear in the Settings UI. "Reset to defaults" SHALL restore it to off (it has no system side effect, permission, or download to preserve).

#### Scenario: Off by default excludes minimized
- **WHEN** the app runs for the first time
- **THEN** minimized windows do not appear in the switcher or ⌘-Tab

#### Scenario: On, minimized windows appear and are badged
- **WHEN** the user turns the opt-in on
- **THEN** minimized windows appear in the switcher and ⌘-Tab, badged as minimized, taking effect on the next gesture without a restart

#### Scenario: Selecting a minimized window restores it in place
- **WHEN** the opt-in is on and the user commits a minimized window
- **THEN** the window is un-minimized in its prior position and raised with focus

#### Scenario: Independent of non-standard inclusion
- **WHEN** the include-minimized-windows opt-in is on and the include-non-standard-windows setting is off
- **THEN** minimized standard windows are listed while non-standard windows remain excluded

#### Scenario: Persists across launches
- **WHEN** the user enables the opt-in and relaunches
- **THEN** the setting is retained and applied

### Requirement: Swipe-down minimize-all opt-in
The system SHALL expose a "minimize all windows on three-finger down" opt-in, **off by default**, that replaces the synthesized App Exposé down-action with the minimize-all-windows action (reveal the desktop by minimizing every current-Space window). It SHALL be *effective* only while the Space-row switching opt-in is effective — otherwise the OS owns three-finger-vertical and the app never receives the down-swipe — and SHALL have no effect when that opt-in is off. To prevent stranding the windows it minimizes, enabling this opt-in SHALL auto-enable the include-minimized-windows opt-in, and the Settings UI SHALL prevent disabling include-minimized-windows while this opt-in is on. It SHALL persist across launches and appear in the Settings UI. "Reset to defaults" SHALL restore it to off.

#### Scenario: Off by default keeps App Exposé on the down-swipe
- **WHEN** the app runs for the first time and the Space-row switching opt-in is effective
- **THEN** a three-finger down swipe performs App Exposé, not minimize-all

#### Scenario: Enabling makes down minimize all windows
- **WHEN** the Space-row switching opt-in is effective and the user enables the swipe-down minimize-all opt-in
- **THEN** a three-finger down swipe minimizes all current-Space windows and reveals the desktop instead of performing App Exposé

#### Scenario: Inert without the vertical opt-in
- **WHEN** the Space-row switching opt-in is off and the swipe-down minimize-all opt-in is on
- **THEN** three-finger vertical is owned by the OS and the app performs no minimize-all (the setting has no effect)

#### Scenario: Enabling auto-enables minimized reachability
- **WHEN** the user enables the swipe-down minimize-all opt-in while include-minimized-windows is off
- **THEN** include-minimized-windows is turned on automatically, and the UI does not allow turning it back off while minimize-all remains on

#### Scenario: Persists across launches
- **WHEN** the user enables the opt-in and relaunches
- **THEN** the opt-in remains enabled and is reapplied

