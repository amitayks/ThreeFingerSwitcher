## ADDED Requirements

### Requirement: Built-in player opt-in and tunables
The settings SHALL expose a built-in media player opt-in that defaults to OFF and gates whether opening a playable media file from the Files band plays it in the in-app player. Like the clipboard-history and device-link opt-ins, it SHALL relocate no native gesture, require no re-login, and have no effectiveness gate — it takes effect immediately when toggled. The settings SHALL also expose, persisted and live-applied: per-media-kind default-open flags (video, audio, image); the default playback engine (AVFoundation default, libmpv alternative); the seek step and volume step (reusing the edge-triggered auto-repeat acceleration); and the resume threshold and near-end margin. Settings written before this change SHALL load with the player opt-in OFF and the tunables at their defaults, without resetting existing settings.

#### Scenario: Opt-in defaults off and persists
- **WHEN** a fresh settings store is read
- **THEN** the player opt-in is false; setting it true and reloading reads back true

#### Scenario: Toggling needs no re-login or effectiveness gate
- **WHEN** the user turns the player opt-in on
- **THEN** the built-in player becomes the open target for the enabled kinds immediately, with no re-login, native-gesture change, or effectiveness gate

#### Scenario: Player tunables are adjustable and persisted
- **WHEN** the user adjusts the per-kind default-open flags, default engine, seek/volume steps, or resume threshold
- **THEN** the new values persist across launches and apply to subsequent opens

#### Scenario: Legacy settings load with the player off and defaults
- **WHEN** settings written before this change are loaded
- **THEN** they decode successfully with the player opt-in OFF and the player tunables at their defaults, and existing settings are not reset
