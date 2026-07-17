# Fix: single-flight model loading + bounded GPU buffer cache

## Why

Two evidence-backed memory defects make the AI feel like it reloads on every trigger and respond slowly even when loaded. (1) The unified log caught two overlapping `prepare: begin gemma-4-31b` runs: `ModelManager.loadIfNeeded()` awaits the heavy provisioner on the main actor, so a second AI touch during the ~8s suspension sees `residentRuntime == nil` and starts a **second full ~17 GB load** — ~40 GB of unified memory on a 48 GB machine, a swap storm, and evicted weight pages that make every subsequent trigger re-page gigabytes (reads as "loading again"). (2) `footprint` shows **24 GB of dirty GPU memory for a 17 GB model** after one small chat: nothing bounds MLX's Metal buffer cache (`MLX.GPU.set(cacheLimit:)` is never called; the vendored pipeline clears only on `unload()`), so freed generation buffers accumulate and never return to the OS — sustained pressure, progressively slower responses. The recent model-cache relocation is innocent (weights migrated intact, one-time rename); it merely landed alongside the changes that widened the concurrent-load window.

## What Changes

- **Single-flight model loading:** `ModelManager` coalesces concurrent loads — one in-flight load task, keyed by the descriptor it serves; concurrent callers for the same descriptor JOIN it (the provisioner runs exactly once); a caller for a different descriptor awaits the in-flight load before proceeding (never two provisioners at once). The task clears on completion, failure, and cancellation.
- **Bounded MLX Metal buffer cache:** `GemmaRuntime`'s composition root sets `MLX.GPU.set(cacheLimit:)` once (a documented constant), so the resident footprint settles near the model's actual size instead of creeping.
- Core regression test: two concurrent `loadIfNeeded()` calls over a slow counting provisioner run it exactly once and both receive the same runtime.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `on-device-ai-runtime`: the model-lifecycle requirement gains single-flight loading (concurrent requests join one load; the load cost is paid once) and a bounded GPU buffer cache (the runtime returns freed generation memory to the OS instead of caching without bound).

## Impact

- **Code**: `Sources/ThreeFingerSwitcher/AI/ModelManager.swift` (in-flight load task + join logic in `loadIfNeeded`/`loadDescriptor`), `Sources/GemmaRuntime/GemmaRuntime.swift` (GPU cache limit at composition). MLX-free Core stays MLX-free — the cache limit lives only in the MLX-linked target.
- **Tests**: `ModelManagerTests` gains the concurrency regression (counting provisioner, deterministic).
- **Out of scope**: `ResidencyPlanner` headroom (`residencyBytes` underestimating the true footprint) is owned by the in-flight `ai-model-fleet` change; the vendored `gemma-4-swift-mlx` checkout is never edited.
- **User-visible**: one cold load per launch at most, shared by every concurrent caller; footprint bounded near the model size; response speed stops degrading with use.
