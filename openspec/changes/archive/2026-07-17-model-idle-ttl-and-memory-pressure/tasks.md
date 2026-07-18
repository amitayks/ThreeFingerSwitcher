# Tasks: model-idle-ttl-and-memory-pressure

## 1. Pure policy core (MLX-free, fully testable)

- [x] 1.1 Add `MemoryPressureLevel` (`.nominal/.warning/.critical`) and `QuiescenceSnapshot` (`turnInFlight`, `foregroundSessionActive`, `nextScheduledWork: Date?`) types in `Sources/ThreeFingerSwitcher/AI/` (Core)
- [x] 1.2 Implement pure `EvictionPolicy.verdict(now:lastActivity:pressure:quiescence:ttl:)` returning `.keep` / `.evict(reason:)` per design D1 (critical = no turn/load in flight; warning = fully quiescent; TTL = continuously quiescent ≥ ttl; `ttl == 0` disables TTL only)
- [x] 1.3 Unit-test every policy rule with faked inputs (each spec scenario becomes a test case: TTL fires, ttl=0 never fires, warning respects foreground session, critical evicts between turns, mid-turn/mid-load keeps, scheduled work blocks quiescence)

## 2. Pressure observer seam

- [x] 2.1 Define `MemoryPressureObserving` (current level + change callback) in Core; add a settable `FakeMemoryPressureSource` for tests
- [x] 2.2 Implement the real `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])` wrapper in the app composition root (app target, ~20 lines; main-actor delivery)

## 3. ModelManager integration

- [x] 3.1 Inject `quiescence: @MainActor () -> QuiescenceSnapshot` and the pressure source into `ModelManager` (same injected-probe idiom as `fleetFreeBytes`/`hardwareSupports`; defaults keep existing tests green)
- [x] 3.2 Stamp `lastAIActivity` on every successful `runtime(requiring:)` return
- [x] 3.3 Add the coarse ~60s evaluation tick + immediate evaluation on pressure events; both call the pure policy and execute `.evict` through the existing `evict()`
- [x] 3.4 Execution-time guards: abort the evict if a load (`coalescedLoad`) or turn is in flight at execution (re-check, not just policy-time); exempt the CPU ternary lane's runtime
- [x] 3.5 Verify lifecycle transitions `loaded → ready` on automatic evict and that the next `runtime(requiring:)` transparently re-loads single-flight (integration test in Core with stub runtime)

## 4. Quiescence signal from the scheduler

- [x] 4.1 Expose `turnInFlight` / `foregroundSessionActive` / `nextScheduledWork` from the parked-sessions scheduler (`NotchSessionEngine` / scheduler seam) — read-only snapshot, no behavior change to sessions; `foregroundSessionActive` is designed as an OR over conversational surfaces so the voice change can add its session without touching the policy
- [x] 4.2 Wire the snapshot closure in `AppCoordinator` composition (both the real path and the Dev/stub path)
- [x] 4.3 Test: an advance scheduled after an evict lazy-loads and completes (never a lost turn) — deterministic with faked time

## 5. Settings + honest comments

- [x] 5.1 Add `AppSettings.aiIdleEvictMinutes` (default 60, `0` = never), surfaced next to the existing model-management controls; persist + clamp
- [x] 5.2 Fix the aspirational comments: `ModelManager.swift` evict/memory-pressure doc comments now describe the wired behavior; `LLMRuntime.swift:355` `maxConcurrentStreams` claim either backed by the D7 recompute poke or corrected
- [x] 5.3 D7 (narrow): on a pressure event with a batched turn in flight, poke the resident batched runtime to recompute `maxConcurrentStreams` from a fresh free-memory probe — or, if it doesn't land cleanly, correct the doc comment and note why in the change

## 6. Spec + verification

- [x] 6.1 `swift build` && `swift test` pass (all new logic is MLX-free Core); `xcodebuild` compile-verify for the app target (composition-root wrapper)
- [x] 6.2 Manual verification plan for the user's signed build: load model, idle past TTL → Settings row reads "Ready"; simulate pressure (`sudo memory_pressure -l warn/critical`) with and without an open chat; confirm next message transparently reloads
- [ ] 6.3 Run `openspec sync` / archive flow: fold the delta into `openspec/specs/on-device-ai-runtime/spec.md` after implementation is verified
