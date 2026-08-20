## ADDED Requirements

### Requirement: Realtime scheduling posture

The process SHALL opt out of App Nap for its whole lifetime (a never-frontmost `LSUIElement` accessory is otherwise demoted exactly when other apps are busy — starving the touch consumer and the event taps), and this opt-out SHALL NOT prevent the system's own idle sleep. The process SHALL also bound every Accessibility round-trip it makes with a process-global messaging timeout well under one second (the system default is 6 seconds per call, and the gesture path makes several calls per window synchronously) — a peer app that cannot answer within the timeout drops out of that one enumeration rather than stalling the gesture.

#### Scenario: Background load does not add trigger latency
- **WHEN** other applications are consuming heavy CPU and the app has been idle in the background
- **THEN** the gesture trigger still fires without a "wake up" delay attributable to App Nap demotion or timer coalescing

#### Scenario: A hung peer app cannot stall the switcher
- **WHEN** the switcher opens while one running app's main thread is hung
- **THEN** window enumeration completes with that app's windows possibly absent from this snapshot, instead of the trigger blocking for multiple seconds

#### Scenario: The Mac still sleeps
- **WHEN** the machine reaches its idle-sleep timeout with the app running
- **THEN** system sleep proceeds normally (the opt-out covers App Nap only)

### Requirement: No subprocess or disk I/O on the gesture path

Opening the switcher or the launcher from a gesture SHALL NOT spawn a subprocess, block on disk I/O, or perform a full-payload computation on the main thread. State that is expensive to read (native-gesture relocation state read via `defaults`, clipboard previews backed by blob files, app icons) SHALL be read off the gesture path and cached for it.

#### Scenario: Switcher open with Space-row switching on
- **WHEN** the user opens the switcher with the Space-row opt-in active
- **THEN** the overlay appears without a `defaults` subprocess being spawned (the relocation state comes from the gate computed when the opt-in last changed)

#### Scenario: Launcher open after a relaunch with large clipboard entries
- **WHEN** the launcher opens with clipboard history containing entries whose payloads live in blob files
- **THEN** the band builds from cached bounded previews after the first build, without re-reading the blobs on the gesture path
