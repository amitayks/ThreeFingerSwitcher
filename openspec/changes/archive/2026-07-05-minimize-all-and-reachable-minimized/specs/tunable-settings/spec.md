## ADDED Requirements

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
