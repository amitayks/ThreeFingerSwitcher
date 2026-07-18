# Tasks: voice-double-tap-dwell-trigger

## 1. Implementation

- [x] 1.1 Rewrite `PTTArmingModel` as the double-tap-then-hold grammar (idle/firstDown/awaitingSecond/dwelling/held/inert; single one-shot timer per phase) + full transition tests
- [x] 1.2 `PTTKeyMonitor` drives the new model (single pending timer; kinds tapMax/gap/dwell)
- [x] 1.3 Hub caption teaches the gesture
- [x] 1.4 `swift build` + full `swift test` green; archive with spec sync
