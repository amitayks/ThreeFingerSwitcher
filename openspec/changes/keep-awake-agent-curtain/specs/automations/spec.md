## MODIFIED Requirements

### Requirement: Keep Awake can guard the Mac — any input stops it and locks the screen
The Keep Awake item SHALL carry a per-item **guard** with three modes: **Off**, **Lock**, **Curtain** (persisted as decode-safe optionals `lockOnStop`, `curtain`; Lock wins if both are set; items saved before the curtain existed decode with it off). In Lock and Curtain modes, once the session has armed, the guard SHALL block input from a person or an untrusted app (see the curtain requirement) and SHALL open an owner check on the first blocked input. In Lock mode, a successful check SHALL end the session **without** locking; a failed, cancelled or timed-out check SHALL lock the screen **before** the curtain is removed and **before** brightness is restored. Explicit stops (re-fire, menu-bar Stop) and teardown stops (quit, will-sleep) SHALL never lock. When the guard is Off, the first trackpad contact ends the session and nothing is blocked.

#### Scenario: The owner returns (Lock mode)
- **WHEN** a guarded session is armed and the owner touches Touch ID (or the trackpad, then Touch ID)
- **THEN** one Touch ID check opens, the owner's finger ends the session, and the screen is restored without a lock screen

#### Scenario: A stranger (Lock mode)
- **WHEN** a guarded session is armed and a person's input arrives and the check fails, is cancelled, or is not answered within 20 s
- **THEN** the screen locks before the curtain is removed and before brightness is restored

## ADDED Requirements

### Requirement: Trusted apps keep control while the guard is up
The app SHALL keep a global **trusted apps** list (bundle ids; default Vex `ai.shift.vex.desktop`), editable on the General page from running apps or any app chosen from disk. Input synthesized by a process whose responsible app is on the list, or by this app, SHALL pass the guard. Hardware input and input from any other process SHALL be treated as a person. An event whose source process cannot be resolved SHALL be treated as untrusted.

#### Scenario: An agent works the Mac behind the guard
- **WHEN** the guard is up and Vex's helper posts clicks and keys
- **THEN** they reach their target apps and the guard does not react

#### Scenario: An app not on the list
- **WHEN** the guard is up and a process whose responsible app is not trusted posts input
- **THEN** the input is blocked and counts as an intrusion

### Requirement: The curtain blocks the outside world while agents work
In Curtain mode, once armed, the guard SHALL swallow every input event (pointer, keys, modifiers, scroll, gestures, system-defined) that is not from a trusted app, so it never reaches any app, while trusted input passes. The first blocked input or trackpad contact SHALL open ONE Touch ID check (no password button). Success SHALL end the session with no lock. Failure SHALL keep the curtain up and ignore further input for 5 s. Without biometrics, the system password prompt MAY be used, with input passed through only while that check is open (≤ 20 s). If the curtain cannot be installed, the guard SHALL fall back to the passive monitor and an input-path stop SHALL lock.

#### Scenario: A stranger behind the curtain
- **WHEN** a curtain session is armed and a person clicks, types or swipes
- **THEN** nothing reaches any app, one Touch ID check opens, and after a failure the curtain stays up

#### Scenario: Curtain unavailable
- **WHEN** the event tap cannot be installed
- **THEN** the passive monitor guards the session and the first input locks the screen

### Requirement: A crash never leaves the curtain's Mac open
While a curtain is up, a watchdog process SHALL lock the screen if the app's process ends while the curtain marker is present. A clean stop SHALL remove the marker so the watchdog exits without locking.

#### Scenario: The app is force-quit behind the curtain
- **WHEN** the app dies while the curtain is up
- **THEN** the watchdog locks the screen within about a second

### Requirement: Guard events are observable
The guard SHALL log each intrusion and check outcome to `~/Library/Logs/ThreeFingerSwitcher/keep-awake-guard.log` and, when configured, run the user's hook command with `TFS_GUARD_EVENT` (`intrusion` once per session, `auth-ok`, `auth-failed`) and `TFS_GUARD_DETAIL`.

#### Scenario: Notify the owner
- **WHEN** a hook is configured and someone touches the guarded Mac
- **THEN** the hook runs with `TFS_GUARD_EVENT=intrusion`
