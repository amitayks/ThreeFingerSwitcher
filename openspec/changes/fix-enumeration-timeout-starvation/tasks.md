# Tasks

- [x] Single-flight `enumeration()` + generation guard + `cachedContentIssuedAt` ordering
- [x] `enumerationWait` 3 s < `sweepStaleAfter` 4 s (test asserts)
- [x] `enumerationCeiling` 15 s hung-replacement
- [x] Stale-while-refresh (`cacheDecision`)
- [x] `warmUp` and `diagnosticFrames` use the shared path
- [x] Window-count report + leak warning in diagnostics
- [x] `swift build`; `swift test` 874 tests, 0 unexpected failures
- [ ] Field check on the work Mac (leak present or simulated): previews appear, `TFS_THUMB_LOG=1` shows one enumeration at a time
- [ ] Amitay approves → merge, release
