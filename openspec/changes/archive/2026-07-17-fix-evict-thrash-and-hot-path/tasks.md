# Tasks: fix-evict-thrash-and-hot-path

## 1. Policy + snapshot

- [x] 1.1 `EvictionPolicy.warningIdleFloor` (300 s): `.warning` evicts only when fully quiescent AND idle ≥ floor; tests updated + new chronic-pressure-between-turns test
- [x] 1.2 `AICommandExecutor.isTurnInFlight` (`.loadingModel`/`.streaming`); coordinator snapshot ORs executor turn, `.reviewingAction`/canvas as foreground-active, notch, voice
- [x] 1.3 Eviction timer tolerance (10 %)

## 2. Hot path

- [x] 2.1 `agentActingNow`/`voicePhaseLive` stored flags fed by sinks inside the lazy initializers; onFrame checks the flags only

## 3. Verify + archive

- [x] 3.1 `swift build` + full `swift test` green; archive with spec sync
