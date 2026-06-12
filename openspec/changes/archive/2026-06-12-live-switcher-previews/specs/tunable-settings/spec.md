## ADDED Requirements

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
