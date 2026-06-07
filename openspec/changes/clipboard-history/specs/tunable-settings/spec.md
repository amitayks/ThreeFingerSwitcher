## ADDED Requirements

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
