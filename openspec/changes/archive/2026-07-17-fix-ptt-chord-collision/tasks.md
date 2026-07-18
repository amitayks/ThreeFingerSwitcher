# Tasks: fix-ptt-chord-collision

## 1. Implementation

- [x] 1.1 Pure `PTTArmingModel` (idle → arming → held; otherKeyDown cancels arming; sub-window release is a no-op) + transition tests
- [x] 1.2 `PTTKeyMonitor` drives the model: `.keyDown` added to the passive masks, one-shot arming timer, `onDown` only on arming-elapsed, `onUp` only from held
- [x] 1.3 `SpeechAnalyzerTranscriber` process-wide asset-check cache
- [x] 1.4 `swift build` + full `swift test` green; archive with spec sync
