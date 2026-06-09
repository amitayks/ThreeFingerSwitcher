## ADDED Requirements

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
With the AI commands opt-in on, the settings SHALL let the user manage the on-device model: see which Gemma 4 model is selected, see download status and size, trigger or retry the download, and evict the resident model from memory. These controls SHALL persist their state across launches and apply immediately.

#### Scenario: Download status is visible
- **WHEN** the user opens settings with the opt-in on and a model downloading
- **THEN** the settings show the model identity, size, and download progress/status

#### Scenario: Evict frees memory immediately
- **WHEN** the user chooses to evict the resident model
- **THEN** the model is unloaded from memory and the next command reloads it on demand

### Requirement: AI command authoring is reachable from settings
The settings SHALL provide access to the AI command authoring UI (create/edit/reorder/delete commands), consistent with how other launcher configuration is reached.

#### Scenario: Open the command editor from settings
- **WHEN** the user opens settings with the opt-in on and chooses to manage AI commands
- **THEN** the command authoring UI opens, showing the current commands
