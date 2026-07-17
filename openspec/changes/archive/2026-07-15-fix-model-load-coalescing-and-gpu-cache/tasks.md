# Tasks — fix-model-load-coalescing-and-gpu-cache

## 1. Single-flight loading (Core)

- [x] 1.1 `ModelManager`: add `loadTask: Task<LLMRuntime, Error>?` + `loadTaskDescriptorID: String?`; a private join-or-start helper wraps the existing load body — same-descriptor callers join, different-descriptor callers drain the in-flight load then re-check, start records + defer-clears the task on all exits
- [x] 1.2 Route `loadIfNeeded()` and `loadDescriptor(_:)` through the helper (warm fast paths unchanged); explicit cancel paths clear the in-flight task
- [x] 1.3 `ModelManagerTests`: counting slow provisioner — (a) two concurrent `loadIfNeeded()` → provisioner runs once, both get the runtime; (b) `runtime(requiring:)` racing `loadIfNeeded()` → once; (c) failing provisioner propagates to both joiners and a retry starts a fresh load

## 2. Bounded GPU buffer cache (GemmaRuntime)

- [x] 2.1 `GemmaRuntime`: idempotent `configureGPUCacheLimit()` (documented 2 GB constant via `MLX.GPU.set(cacheLimit:)`), called from `makeModelManager` and `makeImageRuntime` alongside `configureModelStorage()`

## 3. Verify

- [x] 3.1 `swift build` + `swift test` green (Core stays MLX-free)
- [x] 3.2 `xcodebuild` compile-verify the app target (no install/launch)
- [ ] 3.3 User run-verify on a stable-signed build: trigger AI twice in quick succession from cold (one load in the unified log, no overlapping `prepare`), and `footprint` settles near the model size after several turns — PENDING the user's own Terminal
