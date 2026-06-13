## ADDED Requirements

### Requirement: Device-link opt-in
Settings SHALL expose an `enableDeviceLink` opt-in (default OFF) that gates the device-link receive/send service. Like the clipboard-history opt-in, it relocates no native gesture, needs no re-login, and has no `is…Effective` gate — it takes effect immediately when toggled. It SHALL persist across launches, and settings written before it existed SHALL load with it OFF.

#### Scenario: Default off and persists
- **WHEN** a fresh settings store is read
- **THEN** `enableDeviceLink` is false; setting it true and reloading reads back true

#### Scenario: Legacy settings load with it off
- **WHEN** settings written before this opt-in existed are loaded
- **THEN** `enableDeviceLink` reads as false (no key present)
