## MODIFIED Requirements

### Requirement: Enumerate normal windows across all Spaces
The system SHALL enumerate normal application windows across all Spaces and SHALL snapshot this ordered list at the start of each gesture. Minimized windows SHALL be excluded by default; when the **include-minimized-windows** setting is on, minimized windows SHALL also be enumerated, each flagged as minimized so a consumer can badge it and select the un-minimize commit path.

#### Scenario: Includes windows on other Spaces
- **WHEN** the window list is built
- **THEN** normal windows on Spaces other than the current one are included

#### Scenario: Excludes minimized windows by default
- **WHEN** a window is minimized and the include-minimized-windows setting is off
- **THEN** it is not included in the switcher list

#### Scenario: Includes minimized windows when the setting is on
- **WHEN** a window is minimized and the include-minimized-windows setting is on
- **THEN** it is included in the switcher list and flagged as minimized

#### Scenario: Snapshot is frozen during gesture
- **WHEN** a gesture begins
- **THEN** the ordered window list is captured once and not re-ordered while scrubbing

### Requirement: Switchable-window gate with optional non-standard inclusion
The system SHALL treat a window as switchable only when it is a window-role Accessibility element on the normal window layer, is not minimized — **unless the include-minimized-windows setting is on, in which case a minimized window-role element passes the gate and is flagged minimized** — and — by default — reports the standard-window subrole (a window that exposes no subrole at all is treated as standard). The system SHALL provide a user-configurable setting to relax the subrole requirement: when enabled, any window-role element on the normal window layer is switchable regardless of its subrole, surfacing real windows that report a non-standard or absent subrole (e.g. windows from foreign UI toolkits such as the Android emulator, and setup/welcome windows such as Xcode's start window). The relaxation SHALL apply consistently to both current-Space enumeration and off-Space enumeration (the off-Space element acquisition SHALL widen its own subrole filter to match, so a qualifying non-standard window is acquirable and raisable off-Space). The **include-minimized-windows** setting and the **include-non-standard-windows** setting SHALL be independent (either may be on without the other). The normal-window-layer gate SHALL continue to apply in all modes, so floating HUD/utility panels (windows above the normal window layer) remain excluded regardless of either setting. In relaxed (non-standard) mode the system SHALL additionally exclude windows below a minimum size, measured by the window's real (Accessibility) size so a window shown as a small Stage-Manager strip proxy is measured by its true size and not mis-filtered; this drops the tiny helper/shadow/toolbar surfaces that foreign toolkits expose as extra windows of the same process (which would otherwise appear as a spurious second entry that merely re-fronts the app's real window). Both settings SHALL default to off (strict, minimized-excluded) and SHALL take effect on the next gesture without a restart.

#### Scenario: Strict mode lists only standard windows
- **WHEN** the non-standard setting is off and a process exposes a non-standard-subrole window (e.g. a dialog, panel, or foreign-toolkit window) alongside its standard document windows
- **THEN** the non-standard window is not included in the switcher list while the standard windows are

#### Scenario: Relaxed mode includes non-standard windows
- **WHEN** the non-standard setting is on and a process exposes a window-role window with a non-standard or absent subrole on the normal window layer
- **THEN** that window is included in the switcher list

#### Scenario: Relaxation applies across Spaces
- **WHEN** the non-standard setting is on and a qualifying non-standard window is on another Space
- **THEN** it is enumerated and can be raised, the same as an off-Space standard window

#### Scenario: Minimized inclusion is independent of non-standard inclusion
- **WHEN** the include-minimized-windows setting is on and the include-non-standard-windows setting is off
- **THEN** minimized standard windows are included and flagged minimized, while non-standard (non-minimized) windows remain excluded

#### Scenario: Floating panels still excluded regardless of settings
- **WHEN** either or both settings are on
- **THEN** windows above the normal window layer (floating HUD/utility panels) are still excluded

#### Scenario: Tiny helper windows excluded when relaxed
- **WHEN** the non-standard setting is on and a process (e.g. a foreign-toolkit app) exposes both a real window and a tiny helper/toolbar window on the normal window layer
- **THEN** the real window is included but the tiny helper window (below the minimum size, by its real size) is excluded, so the app appears once rather than as a spurious small second entry

### Requirement: App-scoped current-Space enumeration including minimized windows
The system SHALL provide an enumeration variant that returns the normal windows of a **single application** on the **current Space only**, and — unlike the switcher's default all-Spaces enumeration — **including minimized windows**. Each returned window SHALL carry whether it is minimized so a consumer can badge it and choose the correct commit path. This variant SHALL NOT itself alter the switcher's enumeration; it is an additive mode. (The switcher may independently include minimized windows when its own include-minimized-windows setting is on — governed by the enumeration/gate requirements above — but that is not driven by this variant.) When Accessibility access is unavailable, the variant SHALL degrade without error and without introducing any new permission prompt.

#### Scenario: Returns only the requested app on the current Space
- **WHEN** the app-scoped current-Space variant is queried for application A
- **THEN** it returns A's normal windows on the current Space and no windows of other applications or other Spaces

#### Scenario: Includes minimized windows flagged as minimized
- **WHEN** application A has minimized windows on the current Space
- **THEN** those windows are included in the result and each is flagged as minimized

#### Scenario: This variant does not alter switcher enumeration
- **WHEN** the switcher's enumeration runs with its own include-minimized-windows setting off
- **THEN** it still spans all Spaces and excludes minimized windows; the app-scoped variant does not change that

#### Scenario: Degrades without Accessibility
- **WHEN** Accessibility access is not granted
- **THEN** the variant returns no error and prompts for no new permission

## ADDED Requirements

### Requirement: Minimize all current-Space windows
The system SHALL provide an operation that minimizes every switchable window on the **current Space** — setting each window's Accessibility minimized state — to reveal the desktop (a real minimize into the Dock, not the native slide-aside "Show Desktop"). It SHALL apply the same switchable gate as the switcher (excluding the app's own windows, floating/non-standard surfaces per the current settings, and windows that are already minimized), SHALL operate on the current Space only, and SHALL be idempotent (an already-minimized window is left as-is). A window whose minimize write fails SHALL NOT prevent the remaining windows from being minimized, and any failure SHALL surface as observable state per the error taxonomy rather than a silent success or an app-modal alert.

#### Scenario: Minimizes current-Space windows to reveal the desktop
- **WHEN** the minimize-all operation runs with several normal windows open on the current Space
- **THEN** each of those windows is minimized (its Accessibility minimized state set) and the desktop is revealed

#### Scenario: Leaves own and already-minimized windows alone
- **WHEN** the minimize-all operation runs and some windows are already minimized (and the app's own Hub/overlay windows are present)
- **THEN** already-minimized windows are unchanged and the app's own windows are not minimized

#### Scenario: Does not minimize off-Space windows
- **WHEN** the minimize-all operation runs while windows exist on other Spaces
- **THEN** only current-Space windows are minimized and windows on other Spaces are left as they were

#### Scenario: A single failed minimize does not block the others
- **WHEN** minimizing one window fails
- **THEN** the remaining current-Space windows are still minimized and the failure is recorded as observable state, not surfaced as a false success or an app-modal alert
