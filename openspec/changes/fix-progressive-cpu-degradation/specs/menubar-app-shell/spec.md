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
