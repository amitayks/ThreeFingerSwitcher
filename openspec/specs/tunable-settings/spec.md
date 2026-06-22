# tunable-settings Specification

## Purpose

Define the settings model, persistence, defaults, and Settings UI for the switcher's sensitivity, stepping, and behavior tunables.
## Requirements
### Requirement: Tunable gesture parameters
The system SHALL expose tunable parameters with sensible defaults: activation threshold, axis-lock ratio, step distance ("one window per N"), wrap-vs-clamp at list ends, direction (natural/reverse), velocity smoothing factor, and exact-three-fingers requirement.

#### Scenario: Defaults applied on first run
- **WHEN** the app runs for the first time
- **THEN** all tunables have sensible default values and the switcher is usable without configuration

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

### Requirement: AI commands opt-in
The settings SHALL expose an "AI commands" opt-in that defaults to OFF and gates both the AI command band and the on-device model (download and residency). Unlike the Space-row and launcher opt-ins, this opt-in SHALL NOT relocate any native gesture or require a re-login; unlike the clipboard opt-in, enabling it DOES initiate a one-time multi-gigabyte model download (and a calendar task will later request the Calendar permission at first use). Settings saved before this feature SHALL load unchanged with the opt-in OFF, no model downloaded, and no commands.

#### Scenario: Opt-in defaults off and gates the feature
- **WHEN** the app loads with no prior AI settings
- **THEN** the AI commands opt-in is OFF, no model is downloaded, and no AI command band appears

#### Scenario: Enabling needs no re-login or native-gesture change
- **WHEN** the user turns the opt-in on
- **THEN** the band and model become available without a re-login or any native-gesture relocation (a model download begins)

#### Scenario: Older settings load with the feature off
- **WHEN** settings saved before this feature are loaded
- **THEN** they decode successfully with the opt-in OFF and no AI data, and existing settings are not reset

### Requirement: AI model management settings
With the AI commands opt-in on, the settings SHALL let the user manage the on-device model: choose which Gemma 4 model is selected, see the **selected** model's download status and size, trigger or retry the download, evict the resident model from memory, and **delete the selected model's weights from disk**. The displayed status SHALL track the selected model (switching the picker SHALL refresh it). These controls SHALL persist their state across launches and apply immediately.

#### Scenario: Download status is visible
- **WHEN** the user opens settings with the opt-in on and a model downloading
- **THEN** the settings show the model identity, size, and download progress/status

#### Scenario: Status tracks the selected model
- **WHEN** the user switches the model picker to a different model
- **THEN** the status row refreshes to that model's own download/loaded state

#### Scenario: Delete the selected model
- **WHEN** the user deletes the selected, downloaded model
- **THEN** its weights are removed from disk and the row shows it as not-downloaded (re-downloadable)

#### Scenario: Evict frees memory immediately
- **WHEN** the user chooses to evict the resident model
- **THEN** the model is unloaded from memory and the next command reloads it on demand

### Requirement: Device-link opt-in
Settings SHALL expose an `enableDeviceLink` opt-in (default OFF) that gates the device-link receive/send service. Like the clipboard-history opt-in, it relocates no native gesture, needs no re-login, and has no `is…Effective` gate — it takes effect immediately when toggled. It SHALL persist across launches, and settings written before it existed SHALL load with it OFF.

#### Scenario: Default off and persists
- **WHEN** a fresh settings store is read
- **THEN** `enableDeviceLink` is false; setting it true and reloading reads back true

#### Scenario: Legacy settings load with it off
- **WHEN** settings written before this opt-in existed are loaded
- **THEN** `enableDeviceLink` reads as false (no key present)

### Requirement: Persisted Files action-menu and lift settings

The app SHALL persist the Files-band action configuration and SHALL default it to this change's grammar. The persisted settings SHALL include:

- the **per-type action-menu item lists** (file and folder), each an ordered list drawn from the action catalog — defaulting to **file:** Copy as path · Copy · Paste · Open in ▸ and **folder:** Copy as path · Copy · Paste · ‹terminals› · Open in ▸;
- the **Files lift action** — defaulting to **deliver** (with the menu excursion defaulting to the `+1`-finger lift and discard to the four-finger horizontal), stored as part of the Files gesture-binding vocabulary;
- the **curated terminals/editors** allow-list — defaulting to the auto-detected installed set being enabled.

These settings SHALL be included in the app's **reset-to-defaults** semantics and SHALL load to the defaults above when absent or unreadable.

#### Scenario: Defaults reproduce the specified grammar

- **WHEN** the user has never customized the Files action settings
- **THEN** the file and folder menus, the lift action (deliver), and the enabled terminals are exactly the defaults above

#### Scenario: Customizations persist across launches

- **WHEN** the user changes a menu list, the lift action, or the enabled terminals and relaunches
- **THEN** the changes are restored from persistence

#### Scenario: Reset restores defaults

- **WHEN** the user resets settings to defaults
- **THEN** the Files action menus, lift action, and terminal allow-list return to the specified defaults

#### Scenario: Missing or unreadable settings fall back to defaults

- **WHEN** the persisted Files action settings are absent or cannot be decoded
- **THEN** the app loads the specified defaults without error

