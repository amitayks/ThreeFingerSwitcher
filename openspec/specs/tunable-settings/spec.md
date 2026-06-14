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
The system SHALL expose tunable parameters for the launcher: a four-finger activation threshold (the opening fling), an item-step, a context-step, and a dwell-to-arm duration. The item-step and context-step SHALL parameterize the **positional position-step** (offset per step) for item movement versus band switching respectively (a coarser context step keeps band switching deliberate while item movement stays fine), rather than an odometer travel distance. All SHALL persist and appear in the Settings UI. These tunables SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Dwell duration default is brief but deliberate
- **WHEN** the app runs for the first time
- **THEN** the dwell-to-arm duration defaults to a brief deliberate value (on the order of half a second), not a full second

#### Scenario: Changing dwell changes arm time
- **WHEN** the launcher opt-in is enabled and the user increases the dwell-to-arm duration
- **THEN** an item must be rested on longer before it arms

#### Scenario: Changing context-step changes band sensitivity
- **WHEN** the launcher opt-in is enabled and the user increases the context-step
- **THEN** more vertical offset is required to switch context bands

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

### Requirement: Live preview opt-in

The settings store SHALL expose a persisted boolean that enables a live preview of the highlighted window in the switcher overlay. The setting SHALL persist across launches via the standard settings persistence, SHALL default to enabled, and SHALL be reset to enabled by "reset to defaults". The setting SHALL surface as a toggle on the Switcher page of the configuration Hub. When the setting is off, the switcher SHALL show static thumbnails only.

#### Scenario: Persisted across launches
- **WHEN** the user changes the live-preview toggle
- **THEN** the new value is written to persistent settings and is read back on the next launch

#### Scenario: Default enabled
- **WHEN** the app runs with no previously stored value for the setting
- **THEN** live preview is enabled by default

#### Scenario: Surfaced on the Switcher page
- **WHEN** the user opens the Switcher page of the configuration Hub
- **THEN** a "Live preview of the highlighted window" toggle reflecting the persisted value is shown

#### Scenario: Toggling off mid-session stops live capture
- **WHEN** the user turns the toggle off while the overlay is open
- **THEN** continuous live re-capture stops and the switcher reverts to static thumbnails

#### Scenario: Reset to defaults re-enables
- **WHEN** the user invokes "reset to defaults"
- **THEN** the live-preview setting returns to enabled

### Requirement: Device-link opt-in
Settings SHALL expose an `enableDeviceLink` opt-in (default OFF) that gates the device-link receive/send service. Like the clipboard-history opt-in, it relocates no native gesture, needs no re-login, and has no `is…Effective` gate — it takes effect immediately when toggled. It SHALL persist across launches, and settings written before it existed SHALL load with it OFF.

#### Scenario: Default off and persists
- **WHEN** a fresh settings store is read
- **THEN** `enableDeviceLink` is false; setting it true and reloading reads back true

#### Scenario: Legacy settings load with it off
- **WHEN** settings written before this opt-in existed are loaded
- **THEN** `enableDeviceLink` reads as false (no key present)

### Requirement: Positional navigation tunables

The system SHALL expose tunable parameters, with sensible defaults, for the anchored-positional navigation model and its eased auto-repeat, all persisted and live-applied:

- a **footprint→deflection scale** factor (how far the centroid must move relative to the fingers' landing footprint), with a fixed fallback scale used when the footprint is unavailable;
- an **item step** and a (coarser) **band step** — the offset per position-step for item movement vs. band switching;
- a **padding-box size** (`radius`) — how far the position-tracking box extends from center before the margin accelerates (the "make the padding bigger/smaller" control);
- a fixed **edge-margin band** width at the trackpad border that always accelerates (the padding squeezes against it near the edges; `0` disables it);
- an **initial repeat delay** (the gap before the second step once an offset is held in the margin), a **repeat floor** (the fastest interval the curve approaches), and an **acceleration curve** / ramp (how the interval eases from the initial delay toward the floor over dwell duration — a smooth ramp, never an abrupt slow→fast jump);
- a **back-off to stop** distance — how far the offset may retreat from its furthest held point before the center snaps onto the finger and the auto-repeat stops.

These tunables SHALL be surfaced on the Hub Launcher page and SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Defaults give a controllable, eased feel on first run

- **WHEN** the app runs for the first time
- **THEN** the positional box, edge band, and eased repeat curve have sensible defaults so navigation is usable without configuration — the cursor tracks the finger inside the box, holding past it accelerates smoothly toward the floor, and a small move back re-centers and stops

#### Scenario: Changing the padding size changes how far you step before accelerating

- **WHEN** the user increases the padding-box size
- **THEN** more offset from center is available for precise stepping before the margin starts accelerating

#### Scenario: Changing the repeat floor changes top speed

- **WHEN** the user lowers the repeat floor
- **THEN** a held offset reaches a faster maximum auto-repeat rate after dwelling

#### Scenario: Positional tunables persist and live-apply

- **WHEN** the user changes a positional tunable while the launcher opt-in is enabled
- **THEN** the new value is applied to the next navigation without restart and is retained across relaunch

### Requirement: Axis-lock tunables

The system SHALL expose tunable parameters, with sensible defaults, for the directional axis-lock, persisted and live-applied:

- a **commit wedge** — how strongly one axis must dominate the other before a stroke commits to it (the diagonal-drift forgiveness; a larger wedge forgives more off-axis drift), expressed as a ratio or half-angle;
- a **crossing wedge** — a **wider** acceptance half-angle applied to the band-rail → items crossing (the rightward, into-items direction), so an off-axis nudge toward the items enters them rather than switching a band (the "bigger crossing triangle"); larger than the commit wedge;
- a **re-commit hysteresis** — how far the perpendicular axis must exceed the committed axis before the lock switches to it (preventing accidental axis switching from incidental drift).

These tunables SHALL be surfaced on the Hub Launcher page and SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Defaults forgive normal off-axis drift

- **WHEN** the app runs for the first time and the user strokes roughly along an axis with incidental drift
- **THEN** the default commit wedge commits to the intended axis without changing the perpendicular one

#### Scenario: Widening the wedge forgives larger drift

- **WHEN** the user increases the commit wedge
- **THEN** a more steeply-angled stroke still commits to the dominant axis rather than splitting across both

#### Scenario: Widening the crossing wedge eases entering the items

- **WHEN** the user increases the crossing wedge
- **THEN** a more steeply up/down-and-right stroke from the band rail still enters the items rather than switching a band

#### Scenario: Hysteresis prevents accidental axis switching

- **WHEN** the user increases the re-commit hysteresis and then drifts slightly off the committed axis
- **THEN** the lock stays on the committed axis until a clearly deliberate perpendicular turn

#### Scenario: Axis-lock tunables persist and live-apply

- **WHEN** the user changes an axis-lock tunable while the launcher opt-in is enabled
- **THEN** the new value is applied to the next navigation without restart and is retained across relaunch

